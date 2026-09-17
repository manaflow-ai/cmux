import CmuxTerminal
import Foundation

/// Input typed into an optimistic Cloud pane before its native mirror is ready.
///
/// The pane is inserted the moment the user asks for it; once the stable remote
/// terminal id arrives, early keystrokes go straight to that PTY. The adopted
/// native mirror receives only the suffix after that handoff, so the remote
/// shell remains the source of truth for startup output and echo.
final class CloudOptimisticInputRelay: @unchecked Sendable {
    private struct RemoteSink: Sendable {
        let terminalID: String
        let sender: any CloudTuiUntrackedCommandSending
    }

    private let lock = NSLock()
    private var router: CloudTuiManualIOInputRouter?
    private var remoteSink: RemoteSink?
    private var pending: [TerminalManualInput] = []
    private var remoteTail: Task<Void, Never>?
    private var remoteEpoch: UInt64 = 0
    private var remoteGeneration: UInt64 = 0
    private var remoteQueuedCount = 0
    private var requestedRouter: CloudTuiManualIOInputRouter?
    private var discarded = false
    /// Bounded like the router's own queue: a runaway paste into a pane that
    /// never attaches must not grow without limit.
    private let pendingLimit = 4_096

    /// Number of inputs waiting for a router. Diagnostics and tests only.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count + remoteQueuedCount
    }

    /// Callable from Ghostty's I/O thread, like the router it fronts.
    func send(_ input: TerminalManualInput) {
        lock.lock()
        if let router {
            lock.unlock()
            router.send(input)
            return
        }
        guard !discarded else {
            lock.unlock()
            return
        }
        if let remoteSink {
            enqueueRemoteLocked(input, sink: remoteSink)
        } else if pending.count < pendingLimit {
            pending.append(input)
        }
        lock.unlock()
    }

    /// Starts routing input to the remote terminal as soon as its stable id is
    /// known, before the local mirror has resolved a numeric surface id.
    ///
    /// This keeps early keystrokes in the real remote PTY, so shell startup
    /// output and echo retain the same order as a local terminal.
    func bindRemoteTerminal(
        terminalID: String,
        sender: any CloudTuiUntrackedCommandSending
    ) {
        lock.lock()
        guard !discarded, router == nil else {
            lock.unlock()
            return
        }
        if let existing = remoteSink, existing.terminalID == terminalID {
            promoteRequestedRouterIfReadyLocked()
            lock.unlock()
            return
        }
        let sink = RemoteSink(terminalID: terminalID, sender: sender)
        remoteSink = sink
        remoteEpoch &+= 1
        let queued = pending
        pending.removeAll(keepingCapacity: true)
        for input in queued {
            enqueueRemoteLocked(input, sink: sink)
        }
        promoteRequestedRouterIfReadyLocked()
        lock.unlock()
    }

    /// Delivers everything queued so far to `router` and forwards from now on.
    func attach(_ router: CloudTuiManualIOInputRouter) {
        lock.lock()
        // `discard()` fences the current request; an explicit later attach is
        // the retry boundary and is allowed to resume forwarding.
        discarded = false
        requestedRouter = router
        promoteRequestedRouterIfReadyLocked()
        lock.unlock()
    }

    /// Drops queued input and stops forwarding: the request was cancelled or the
    /// pane failed. A later `attach` (retry) resumes forwarding.
    func discard() {
        lock.lock()
        pending.removeAll()
        requestedRouter = nil
        remoteSink = nil
        remoteEpoch &+= 1
        remoteGeneration &+= 1
        remoteTail?.cancel()
        remoteTail = nil
        remoteQueuedCount = 0
        router = nil
        discarded = true
        lock.unlock()
    }

    private func enqueueRemoteLocked(_ input: TerminalManualInput, sink: RemoteSink) {
        remoteQueuedCount += 1
        remoteGeneration &+= 1
        let epoch = remoteEpoch
        let generation = remoteGeneration
        let previous = remoteTail
        remoteTail = Task { [weak self, previous] in
            await previous?.value
            guard !Task.isCancelled else {
                self?.remoteDeliveryFinished(epoch: epoch, generation: generation, input: nil, error: nil)
                return
            }
            do {
                guard let self, self.canDeliverRemote(epoch: epoch) else {
                    self?.remoteDeliveryFinished(
                        epoch: epoch,
                        generation: generation,
                        input: input,
                        error: CancellationError()
                    )
                    return
                }
                guard let request = Self.request(for: input, sink: sink) else {
                    self.remoteDeliveryFinished(epoch: epoch, generation: generation, input: nil, error: nil)
                    return
                }
                try await sink.sender.sendUntrackedTuiCommand(arguments: request)
                self.remoteDeliveryFinished(epoch: epoch, generation: generation, input: nil, error: nil)
            } catch {
                // `sendUntrackedTuiCommand` checks cancellation before writing,
                // so an error means this event did not reach the channel. Keep it
                // for the surface handoff or the next authenticated retry.
                self.remoteDeliveryFinished(epoch: epoch, generation: generation, input: input, error: error)
            }
        }
    }

    private func remoteDeliveryFinished(
        epoch: UInt64,
        generation: UInt64,
        input: TerminalManualInput?,
        error: Error?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded, epoch == remoteEpoch, generation <= remoteGeneration else { return }
        if let input, error != nil, pending.count < pendingLimit {
            pending.append(input)
            // A failed persistent channel is no longer a safe target. A future
            // retry binds a fresh link and drains this event exactly once.
            remoteSink = nil
        }
        remoteQueuedCount = max(0, remoteQueuedCount - 1)
        guard generation == remoteGeneration, remoteQueuedCount == 0 else { return }
        remoteTail = nil
        promoteRequestedRouterIfReadyLocked()
    }

    private func canDeliverRemote(epoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !discarded && epoch == remoteEpoch && remoteSink != nil
    }

    private func promoteRequestedRouterIfReadyLocked() {
        guard router == nil, let requestedRouter,
              remoteTail == nil, remoteQueuedCount == 0 else { return }
        self.requestedRouter = nil
        router = requestedRouter
        // Enqueue the backlog before publishing the router. `send()` only
        // queues work, so this lock never performs socket I/O and a concurrent
        // key cannot overtake earlier input at the handoff boundary.
        for input in pending { requestedRouter.send(input) }
        pending.removeAll(keepingCapacity: true)
    }

    private static func request(
        for input: TerminalManualInput,
        sink: RemoteSink
    ) -> CloudTuiRequest? {
        switch input {
        case .bytes(let bytes):
            guard !bytes.isEmpty else { return nil }
            return CloudTuiRequests.writeBytes(terminalID: sink.terminalID, data: bytes)
        case .namedKey(let name):
            guard let key = CloudTuiManualIOInputRouter.protocolKeyName(for: name) else { return nil }
            return CloudTuiRequests.keysArguments(socketPath: "", terminalID: sink.terminalID, keys: [key])
        }
    }
}

/// A native pane that already occupies the user's requested split or tab while
/// the machine creates the terminal behind it.
///
/// One reservation is one UI intent. The attachment adopts the pane when the
/// remote terminal resolves (`CmuxTuiSurfaceProvider.materialize(…, adopting:)`),
/// a failure is shown inside the pane, and the request is cancelled when the
/// user closes the pane first. While it waits the pane shows nothing but its
/// tab-strip spinner: no progress card, no placeholder text.
@MainActor
final class CloudTerminalPaneReservation {
    let workspaceID: UUID
    let panelID: UUID
    let sourcePlacement: CloudTerminalSourcePlacement
    /// An existing terminal's saved target, never the source tab of a new create.
    let attachmentPlacement: SurfaceResourcePlacement?
    let creationReceipt = CloudTerminalCreationReceipt()
    let inputRelay: CloudOptimisticInputRelay
    /// When the pane was inserted. Adoption hands the elapsed wait to the
    /// attachment session so the connection card does not restart its grace.
    let startedAt: ContinuousClock.Instant
    /// Replays the same request (create receipt first, then projection).
    var retry: (@MainActor () -> Void)?
    /// Cancels the local request; a remote terminal already created stays alive.
    var cancel: (@MainActor () -> Void)?

    init(
        workspaceID: UUID,
        panelID: UUID,
        machine: SurfaceMachineID,
        sourcePlacement: CloudTerminalSourcePlacement? = nil,
        attachmentPlacement: SurfaceResourcePlacement? = nil,
        inputRelay: CloudOptimisticInputRelay = CloudOptimisticInputRelay(),
        startedAt: ContinuousClock.Instant = .now
    ) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.sourcePlacement = sourcePlacement ?? CloudTerminalSourcePlacement(
            machine: machine,
            remoteWorkspaceID: attachmentPlacement?.remoteWorkspaceID,
            remoteTabID: attachmentPlacement?.remoteTabID
        )
        self.attachmentPlacement = attachmentPlacement
        self.inputRelay = inputRelay
        self.startedAt = startedAt
    }

    var machine: SurfaceMachineID { sourcePlacement.machine }
    var remoteWorkspaceID: String? { sourcePlacement.remoteWorkspaceID }
    var remoteTabID: String? { sourcePlacement.remoteTabID }
    var elapsed: Duration { ContinuousClock.now - startedAt }

    /// Rechecks a saved view after attachment awaits and before any queued input is forwarded.
    func validatedAttachmentPlacement(
        resourceID: SurfaceResourceID,
        remoteTabID: String?,
        materializedPlacement: SurfaceRemotePlacement? = nil,
        catalog: SurfaceCatalog
    ) throws -> SurfaceRemotePlacement? {
        guard let expected = attachmentPlacement else { return materializedPlacement }
        guard resourceID == expected.resource, resourceID.machine == machine,
              remoteTabID == nil || expected.remoteTabID == nil || remoteTabID == expected.remoteTabID else {
            throw CloudDiagnosticFailure.placement
        }
        guard expected.remoteWorkspaceID != nil || expected.remoteTabID != nil else { return materializedPlacement }
        guard let view = try? catalog.remoteView(
            for: resourceID, tabID: expected.remoteTabID, workspaceID: expected.remoteWorkspaceID
        ) else { throw CloudDiagnosticFailure.placement }
        if let materializedPlacement,
           materializedPlacement.workspaceID != view.workspace.id || materializedPlacement.tabID != view.tabID {
            throw CloudDiagnosticFailure.placement
        }
        return materializedPlacement ?? SurfaceRemotePlacement(workspaceID: view.workspace.id, tabID: view.tabID)
    }
}
