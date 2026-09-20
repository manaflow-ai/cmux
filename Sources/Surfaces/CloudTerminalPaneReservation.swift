import os
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

    private struct State: @unchecked Sendable {
        var router: CloudTuiManualIOInputRouter?
        var remoteSink: RemoteSink?
        var pending: [TerminalManualInput] = []
        var remoteQueue: [TerminalManualInput] = []
        var remoteQueueHead = 0
        var remoteWorker: Task<Void, Never>?
        var remoteInFlight = false
        var remoteEpoch: UInt64 = 0
        var requestedRouter: CloudTuiManualIOInputRouter?
        var remoteBindingPending = false
        var discarded = false
    }

    // Ghostty's synchronous input callback needs a tiny synchronous bridge.
    // All asynchronous delivery and lifecycle state remains on one retained worker.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pendingLimit = 4_096

    /// Number of inputs retained by the relay. Diagnostics and tests only.
    var pendingCount: Int {
        state.withLock { state in
            state.pending.count + remoteQueueCountLocked(state) + (state.remoteInFlight ? 1 : 0)
        }
    }

    /// Callable from Ghostty's I/O thread, like the router it fronts.
    func send(_ input: TerminalManualInput) {
        let router = state.withLock { state -> CloudTuiManualIOInputRouter? in
            if let router = state.router { return router }
            guard !state.discarded,
                  retainedInputCountLocked(state) < pendingLimit else { return nil }
            if state.remoteSink != nil {
                appendRemoteLocked(input, to: &state)
                startRemoteWorkerLocked(&state)
            } else {
                state.pending.append(input)
            }
            return nil
        }
        router?.send(input)
    }

    /// Marks the relay as awaiting the binding attempt that precedes materialization.
    /// Pending input remains owned by this relay until bindRemoteTerminal succeeds.
    func beginRemoteBinding() {
        state.withLock { state in
            guard !state.discarded, state.router == nil else { return }
            state.remoteBindingPending = true
        }
    }

    /// Starts routing input to the remote terminal as soon as its stable id is known.
    @discardableResult
    func bindRemoteTerminal(
        terminalID: String,
        sender: any CloudTuiUntrackedCommandSending
    ) -> Bool {
        state.withLock { state in
            guard !state.discarded, state.router == nil else { return false }
            state.remoteBindingPending = false
            if let existing = state.remoteSink, existing.terminalID == terminalID {
                promoteRequestedRouterIfReadyLocked(&state)
                return true
            }
            state.remoteSink = RemoteSink(terminalID: terminalID, sender: sender)
            state.remoteEpoch &+= 1
            let pending = state.pending
            appendRemoteLocked(pending, to: &state)
            state.pending.removeAll(keepingCapacity: true)
            startRemoteWorkerLocked(&state)
            promoteRequestedRouterIfReadyLocked(&state)
            return true
        }
    }

    /// Delivers everything queued so far to `router` and forwards from now on.
    func attach(_ router: CloudTuiManualIOInputRouter) {
        state.withLock { state in
            // `discard()` fences the current request; an explicit later attach is
            // the retry boundary and is allowed to resume forwarding.
            state.discarded = false
            state.requestedRouter = router
            promoteRequestedRouterIfReadyLocked(&state)
        }
    }

    /// Drops queued input and stops forwarding. A later `attach` resumes forwarding.
    func discard() {
        state.withLock { state in
            state.pending.removeAll()
            clearRemoteQueueLocked(&state)
            state.requestedRouter = nil
            state.remoteSink = nil
            state.remoteBindingPending = false
            state.remoteEpoch &+= 1
            state.remoteWorker?.cancel()
            state.remoteWorker = nil
            state.remoteInFlight = false
            state.router = nil
            state.discarded = true
        }
    }

    private func startRemoteWorkerLocked(_ state: inout State) {
        guard state.remoteWorker == nil,
              state.remoteSink != nil,
              !remoteQueueIsEmptyLocked(state) else { return }
        let epoch = state.remoteEpoch
        state.remoteWorker = Task { [weak self] in
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
        state.withLock { state in
            guard !state.discarded,
                  epoch == state.remoteEpoch,
                  state.remoteSink != nil,
                  !remoteQueueIsEmptyLocked(state) else { return nil }
            let item = state.remoteQueue[state.remoteQueueHead]
            state.remoteQueueHead += 1
            if state.remoteQueueHead == state.remoteQueue.count {
                clearRemoteQueueLocked(&state)
            } else if state.remoteQueueHead >= 256,
                      state.remoteQueueHead * 2 >= state.remoteQueue.count {
                state.remoteQueue.removeFirst(state.remoteQueueHead)
                state.remoteQueueHead = 0
            }
            state.remoteInFlight = true
            return item
        }
    }

    private func remoteSinkForDelivery(epoch: UInt64) -> RemoteSink? {
        state.withLock { state in
            guard !state.discarded, epoch == state.remoteEpoch else { return nil }
            return state.remoteSink
        }
    }

    private func remoteInputFinished(epoch: UInt64) {
        state.withLock { state in
            guard !state.discarded, epoch == state.remoteEpoch else { return }
            state.remoteInFlight = false
        }
    }

    private func remoteInputFailed(epoch: UInt64, input: TerminalManualInput) {
        state.withLock { state in
            guard !state.discarded, epoch == state.remoteEpoch else { return }
            // Keep failed input and its untouched suffix remote-owned until a
            // fresh authenticated binding succeeds.
            state.pending.append(input)
            if !remoteQueueIsEmptyLocked(state) {
                let suffix = Array(state.remoteQueue[state.remoteQueueHead...])
                state.pending.append(contentsOf: suffix)
            }
            clearRemoteQueueLocked(&state)
            state.remoteSink = nil
            state.remoteBindingPending = true
            state.remoteInFlight = false
        }
    }

    private func remoteWorkerFinished(epoch: UInt64) {
        state.withLock { state in
            guard !state.discarded, epoch == state.remoteEpoch else { return }
            state.remoteWorker = nil
            state.remoteInFlight = false
            startRemoteWorkerLocked(&state)
            promoteRequestedRouterIfReadyLocked(&state)
        }
    }

    private func promoteRequestedRouterIfReadyLocked(_ state: inout State) {
        guard state.router == nil,
              let requestedRouter = state.requestedRouter,
              !state.remoteBindingPending,
              state.remoteWorker == nil,
              remoteQueueIsEmptyLocked(state),
              !state.remoteInFlight else { return }
        state.requestedRouter = nil
        state.router = requestedRouter
        // Enqueue before publishing the router so a concurrent key cannot overtake.
        for input in state.pending { requestedRouter.send(input) }
        state.pending.removeAll(keepingCapacity: true)
    }

    private func retainedInputCountLocked(_ state: State) -> Int {
        state.pending.count + remoteQueueCountLocked(state) + (state.remoteInFlight ? 1 : 0)
    }

    private func remoteQueueCountLocked(_ state: State) -> Int {
        max(0, state.remoteQueue.count - state.remoteQueueHead)
    }

    private func remoteQueueIsEmptyLocked(_ state: State) -> Bool {
        state.remoteQueueHead >= state.remoteQueue.count
    }

    private func appendRemoteLocked(
        _ inputs: [TerminalManualInput],
        to state: inout State
    ) {
        guard !inputs.isEmpty else { return }
        if state.remoteQueueHead > 0 {
            state.remoteQueue.removeFirst(state.remoteQueueHead)
            state.remoteQueueHead = 0
        }
        state.remoteQueue.append(contentsOf: inputs)
    }

    private func clearRemoteQueueLocked(_ state: inout State) {
        state.remoteQueue.removeAll(keepingCapacity: true)
        state.remoteQueueHead = 0
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
