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
    /// Input waiting for a remote terminal or for the explicit surface handoff.
    private var pending: [TerminalManualInput] = []
    /// The single FIFO consumed by `remoteWorker`.
    private var remoteQueue: [TerminalManualInput] = []
    private var remoteWorker: Task<Void, Never>?
    private var remoteInFlight = false
    private var remoteEpoch: UInt64 = 0
    private var requestedRouter: CloudTuiManualIOInputRouter?
    private var discarded = false
    /// Bounds all input retained by this relay, including the in-flight item.
    private let pendingLimit = 4_096

    /// Number of inputs retained by the relay. Diagnostics and tests only.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count + remoteQueue.count + (remoteInFlight ? 1 : 0)
    }

    /// Callable from Ghostty's I/O thread, like the router it fronts.
    func send(_ input: TerminalManualInput) {
        lock.lock()
        if let router {
            lock.unlock()
            router.send(input)
            return
        }
        guard !discarded, retainedInputCountLocked < pendingLimit else {
            lock.unlock()
            return
        }
        if remoteSink != nil {
            remoteQueue.append(input)
            startRemoteWorkerLocked()
        } else {
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
        remoteQueue.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        startRemoteWorkerLocked()
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
        remoteQueue.removeAll()
        requestedRouter = nil
        remoteSink = nil
        remoteEpoch &+= 1
        remoteWorker?.cancel()
        remoteWorker = nil
        remoteInFlight = false
        router = nil
        discarded = true
        lock.unlock()
    }

    private var retainedInputCountLocked: Int {
        pending.count + remoteQueue.count + (remoteInFlight ? 1 : 0)
    }

    private func startRemoteWorkerLocked() {
        guard remoteWorker == nil, remoteSink != nil, !remoteQueue.isEmpty else { return }
        let epoch = remoteEpoch
        remoteWorker = Task { [weak self] in
            while let self, let item = self.takeRemoteInput(epoch: epoch) {
                guard let sink = self.remoteSinkForDelivery(epoch: epoch) else { break }
                do {
                    guard let request = Self.request(for: item, sink: sink) else {
                        self.remoteInputFinished(epoch: epoch)
                        continue
                    }
                    try await sink.sender.sendUntrackedTuiCommand(arguments: request)
                    self.remoteInputFinished(epoch: epoch)
                } catch {
                    self.remoteInputFailed(epoch: epoch, input: item)
                    break
                }
            }
            self?.remoteWorkerFinished(epoch: epoch)
        }
    }

    private func takeRemoteInput(epoch: UInt64) -> TerminalManualInput? {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded, epoch == remoteEpoch, remoteSink != nil,
              let item = remoteQueue.first else { return nil }
        remoteQueue.removeFirst()
        remoteInFlight = true
        return item
    }

    private func remoteSinkForDelivery(epoch: UInt64) -> RemoteSink? {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded, epoch == remoteEpoch else { return nil }
        return remoteSink
    }

    private func remoteInputFinished(epoch: UInt64) {
        lock.lock()
        guard !discarded, epoch == remoteEpoch else {
            lock.unlock()
            return
        }
        remoteInFlight = false
        lock.unlock()
    }

    private func remoteInputFailed(epoch: UInt64, input: TerminalManualInput) {
        lock.lock()
        guard !discarded, epoch == remoteEpoch else {
            lock.unlock()
            return
        }
        // The failing item was removed from the FIFO for delivery. Reinsert it
        // before the untouched suffix, then stop the worker so a retry can bind
        // a fresh authenticated sink without reordering any later input.
        pending.append(input)
        pending.append(contentsOf: remoteQueue)
        remoteQueue.removeAll(keepingCapacity: true)
        remoteSink = nil
        remoteInFlight = false
        lock.unlock()
    }

    private func remoteWorkerFinished(epoch: UInt64) {
        lock.lock()
        guard !discarded, epoch == remoteEpoch else {
            lock.unlock()
            return
        }
        remoteWorker = nil
        remoteInFlight = false
        startRemoteWorkerLocked()
        promoteRequestedRouterIfReadyLocked()
        lock.unlock()
    }

    private func promoteRequestedRouterIfReadyLocked() {
        guard router == nil, let requestedRouter,
              remoteWorker == nil, remoteQueue.isEmpty, !remoteInFlight else { return }
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
