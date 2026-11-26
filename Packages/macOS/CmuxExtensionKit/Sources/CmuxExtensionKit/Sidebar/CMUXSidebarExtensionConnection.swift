import Foundation

/// Lower-level transport object for sidebar extensions.
///
/// Most extension authors should use `CmuxSidebarExtensionScene(_:)`, which owns
/// ExtensionKit scene setup and `NSXPCConnection` handling. This type remains
/// internal so the public SDK keeps extension authors on typed CMUX protocols.
/// `@unchecked Sendable` is safe because mutable transport state is guarded by
/// `lock` or `lifecycleLock`, and callbacks cross back to `@MainActor`.
final class CMUXSidebarExtensionConnection: @unchecked Sendable {
    /// Receives a filtered workspace snapshot from CMUX.
    typealias SnapshotHandler = @MainActor @Sendable (CmuxSidebarSnapshot) -> Void

    /// Receives connection state changes and transport errors.
    typealias StatusHandler = @MainActor @Sendable (CmuxSidebarConnectionStatus) -> Void

    /// Receives the result for a host action request.
    typealias ActionReplyHandler = @MainActor @Sendable (CmuxSidebarActionResult) -> Void

    /// Manifest presented to CMUX for identity, compatibility, and permissions.
    let manifest: CmuxExtensionManifest

    private let onSnapshot: SnapshotHandler
    private let onStatus: StatusHandler
    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private var state = ConnectionState()

    /// Creates a lower-level sidebar transport connection.
    ///
    /// Prefer `CmuxSidebarExtensionScene(_:)` for new extensions.
    init(
        manifest: CmuxExtensionManifest,
        onSnapshot: @escaping SnapshotHandler,
        onStatus: @escaping StatusHandler = { _ in }
    ) {
        self.manifest = manifest
        self.onSnapshot = onSnapshot
        self.onStatus = onStatus
    }

    /// Accepts a host-provided XPC connection.
    ///
    /// Prefer `CmuxSidebarExtensionScene(_:)` for new extensions.
    @discardableResult
    func accept(_ connection: NSXPCConnection) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let generation = nextGeneration(for: connection)

        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.exportedObject = CMUXSidebarExtensionXPCReceiver(
            manifest: manifest,
            receiveSnapshot: { [weak self] payload, receiverGeneration in
                self?.receive(snapshot: Data(referencing: payload), ifCurrentGeneration: receiverGeneration)
            },
            generation: generation
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.invalidationHandler = { [weak self, generation] in
            self?.clearConnection(ifCurrentGeneration: generation)
        }
        connection.interruptionHandler = { [weak self, generation] in
            self?.markInterrupted(ifCurrentGeneration: generation)
        }

        let hostProxy = connection.remoteObjectProxyWithErrorHandler { [weak self, generation] error in
            self?.report(.error(error.localizedDescription), ifCurrentGeneration: generation)
        } as? CMUXSidebarHostXPC
        setHost(hostProxy, ifCurrentGeneration: generation)
        connection.resume()
        return true
    }

    /// Requests a fresh snapshot from CMUX.
    func refreshSnapshot() {
        guard let target = currentHost() else {
            report(.waitingForHost, ifCurrentGeneration: currentGeneration())
            return
        }
        target.host.requestSidebarSnapshot { [weak self, generation = target.generation] payload, error in
            if let error {
                self?.report(.error(String(error)), ifCurrentGeneration: generation)
                return
            }
            guard let payload else {
                self?.report(.error("cmux did not send a workspace snapshot"), ifCurrentGeneration: generation)
                return
            }
            self?.receive(snapshot: Data(referencing: payload), ifCurrentGeneration: generation)
        }
    }

    /// Sends a host action to CMUX.
    func perform(
        _ action: CmuxSidebarAction,
        reply: @escaping ActionReplyHandler = { _ in }
    ) -> CmuxSidebarActionCancellation? {
        guard let target = currentHost() else {
            let message = "Waiting for cmux"
            report(.waitingForHost, ifCurrentGeneration: currentGeneration())
            deliver(.rejected(message), to: reply)
            return nil
        }

        let generation = target.generation
        do {
            let payload = try CmuxSidebarXPCCodec.encodeAction(action)
            let actionID = UUID()
            guard storePendingAction(id: actionID, generation: generation, reply: reply) else {
                deliver(.rejected("cmux connection changed"), to: reply)
                return nil
            }
            target.host.performSidebarAction(payload) { [weak self] resultPayload, error in
                guard let self else {
                    Self.deliver(.rejected("cmux connection was lost"), to: reply)
                    return
                }
                if let error {
                    let message = String(error)
                    guard self.completePendingAction(id: actionID, result: .rejected(message)) else { return }
                    self.report(.error(message), ifCurrentGeneration: generation)
                    return
                }
                guard let resultPayload else {
                    let message = "cmux did not send an action result"
                    guard self.completePendingAction(id: actionID, result: .rejected(message)) else { return }
                    self.report(.error(message), ifCurrentGeneration: generation)
                    return
                }
                do {
                    let result = try CmuxSidebarXPCCodec.decodeActionResult(resultPayload)
                    guard self.completePendingAction(id: actionID, result: result) else { return }
                    if result.accepted {
                        self.report(.connected, ifCurrentGeneration: generation)
                    }
                } catch {
                    let message = error.localizedDescription
                    guard self.completePendingAction(id: actionID, result: .rejected(message)) else { return }
                    self.report(.error(message), ifCurrentGeneration: generation)
                }
            }
            return CmuxSidebarActionCancellation { [weak self] in
                self?.cancelPendingAction(id: actionID)
            }
        } catch {
            let message = error.localizedDescription
            report(.error(message), ifCurrentGeneration: generation)
            deliver(.rejected(message), to: reply)
            return nil
        }
    }

    /// Tears down the current host connection.
    func invalidate() {
        let (connection, pendingReplies, generation) = withState { state in
            state.generation += 1
            let connection = state.connection
            let pendingReplies = Array(state.pendingActions.values.map(\.reply))
            state.connection = nil
            state.host = nil
            state.pendingActions.removeAll()
            return (connection, pendingReplies, state.generation)
        }
        connection?.invalidate()
        deliver(.rejected("cmux connection was closed"), to: pendingReplies)
        report(.waitingForHost, ifCurrentGeneration: generation)
    }

    private func receive(snapshot payload: Data, ifCurrentGeneration generation: UInt64) {
        guard isCurrent(generation) else { return }
        do {
            let snapshot = try CmuxSidebarXPCCodec.decodeSnapshot(payload as NSData)
            deliver(snapshot, ifCurrentGeneration: generation)
        } catch {
            report(.error(error.localizedDescription), ifCurrentGeneration: generation)
        }
    }

    private func deliver(_ snapshot: CmuxSidebarSnapshot, ifCurrentGeneration generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            onSnapshot(snapshot)
            onStatus(.connected)
        }
    }

    private func report(_ status: CmuxSidebarConnectionStatus, ifCurrentGeneration generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            onStatus(status)
        }
    }

    private func deliver(
        _ result: CmuxSidebarActionResult,
        to reply: @escaping ActionReplyHandler
    ) {
        Self.deliver(result, to: reply)
    }

    private func markInterrupted(ifCurrentGeneration generation: UInt64) {
        let repliesToDrain = withState { state -> [ActionReplyHandler]? in
            guard state.generation == generation else { return nil }
            state.host = nil
            let replies = pendingReplies(from: &state, matching: generation)
            return replies
        }
        if let repliesToDrain {
            deliver(.rejected("cmux connection was interrupted"), to: repliesToDrain)
            report(.waitingForHost, ifCurrentGeneration: generation)
        }
    }

    private func clearConnection(ifCurrentGeneration generation: UInt64) {
        let repliesToDrain = withState { state -> [ActionReplyHandler]? in
            guard state.generation == generation else { return nil }
            state.connection = nil
            state.host = nil
            let replies = pendingReplies(from: &state, matching: generation)
            return replies
        }
        if let repliesToDrain {
            deliver(.rejected("cmux connection was closed"), to: repliesToDrain)
            report(.waitingForHost, ifCurrentGeneration: generation)
        }
    }

    private func nextGeneration(for connection: NSXPCConnection) -> UInt64 {
        let (generation, oldConnection, pendingReplies) = withState { state in
            state.generation += 1
            let oldConnection = state.connection
            let pendingReplies = Array(state.pendingActions.values.map(\.reply))
            state.connection = connection
            state.host = nil
            state.pendingActions.removeAll()
            return (state.generation, oldConnection, pendingReplies)
        }
        oldConnection?.invalidate()
        deliver(.rejected("cmux connection changed"), to: pendingReplies)
        return generation
    }

    private func setHost(_ host: CMUXSidebarHostXPC?, ifCurrentGeneration generation: UInt64) {
        withState { state in
            guard state.generation == generation else { return }
            state.host = host
        }
    }

    private func currentHost() -> (host: CMUXSidebarHostXPC, generation: UInt64)? {
        withState { state in
            guard let host = state.host else { return nil }
            return (host, state.generation)
        }
    }

    private func currentGeneration() -> UInt64 {
        withState { state in
            state.generation
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        withState { state in
            state.generation == generation
        }
    }

    private func storePendingAction(
        id: UUID,
        generation: UInt64,
        reply: @escaping ActionReplyHandler
    ) -> Bool {
        withState { state in
            guard state.generation == generation else { return false }
            state.pendingActions[id] = PendingAction(generation: generation, reply: reply)
            return true
        }
    }

    private func completePendingAction(id: UUID, result: CmuxSidebarActionResult) -> Bool {
        let reply = withState { state in
            state.pendingActions.removeValue(forKey: id)?.reply
        }
        guard let reply else { return false }
        deliver(result, to: reply)
        return true
    }

    private func cancelPendingAction(id: UUID) {
        _ = withState { state in
            state.pendingActions.removeValue(forKey: id)
        }
    }

    private func pendingReplies(
        from state: inout ConnectionState,
        matching generation: UInt64
    ) -> [ActionReplyHandler] {
        let matchingActions = state.pendingActions.filter { _, action in
            action.generation == generation
        }
        for id in matchingActions.keys {
            state.pendingActions.removeValue(forKey: id)
        }
        return matchingActions.values.map(\.reply)
    }

    private func deliver(
        _ result: CmuxSidebarActionResult,
        to replies: [ActionReplyHandler]
    ) {
        for reply in replies {
            deliver(result, to: reply)
        }
    }

    private static func deliver(
        _ result: CmuxSidebarActionResult,
        to reply: @escaping ActionReplyHandler
    ) {
        Task { @MainActor in
            reply(result)
        }
    }

    private func withState<Result>(_ body: (inout ConnectionState) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private struct ConnectionState {
    var connection: NSXPCConnection?
    var host: CMUXSidebarHostXPC?
    var generation: UInt64 = 0
    var pendingActions: [UUID: PendingAction] = [:]
}

private struct PendingAction {
    var generation: UInt64
    var reply: CMUXSidebarExtensionConnection.ActionReplyHandler
}

private final class CMUXSidebarExtensionXPCReceiver: NSObject, CMUXSidebarExtensionXPC {
    private let manifest: CmuxExtensionManifest
    private let receiveSnapshot: @Sendable (NSData, UInt64) -> Void
    private let generation: UInt64

    init(
        manifest: CmuxExtensionManifest,
        receiveSnapshot: @escaping @Sendable (NSData, UInt64) -> Void,
        generation: UInt64
    ) {
        self.manifest = manifest
        self.receiveSnapshot = receiveSnapshot
        self.generation = generation
    }

    func requestExtensionManifest(reply: @escaping (NSData?, NSString?) -> Void) {
        do {
            reply(try CmuxSidebarXPCCodec.encodeManifest(manifest), nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func sidebarSnapshotDidChange(_ payload: NSData) {
        receiveSnapshot(payload, generation)
    }
}
