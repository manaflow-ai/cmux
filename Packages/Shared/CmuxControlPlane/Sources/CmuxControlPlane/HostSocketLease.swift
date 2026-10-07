import CmuxMobileWire
import Foundation

/// One feature's use of a shared host socket. `stop()` releases it once:
/// the lease's own streams finish and the pool closes the socket after the
/// last lease.
actor HostSocketLease: ControlPlaneSession {
    private let socket: SharedHostSocket
    private let onRelease: @Sendable () async -> Void
    private let owner = UUID()
    private var released = false

    init(socket: SharedHostSocket, onRelease: @escaping @Sendable () async -> Void) {
        self.socket = socket
        self.onRelease = onRelease
    }

    func start() async {
        guard !released else { return }
        await socket.start()
    }

    func stop() async {
        guard !released else { return }
        released = true
        await socket.drop(owner: owner)
        await onRelease()
    }

    func stateUpdates() async -> AsyncStream<ControlPlaneState> {
        guard !released else { return Self.finished() }
        return await socket.stateUpdates(owner: owner)
    }

    func signalUpdates() async -> AsyncStream<SignalFrame> {
        guard !released else { return Self.finished() }
        return await socket.signalUpdates(owner: owner)
    }

    func subscribe(_ stream: String) async -> AsyncStream<StreamUpdate> {
        guard !released else { return Self.finished() }
        return await socket.subscribe(stream, owner: owner)
    }

    func unsubscribe(_ stream: String) async {
        await socket.unsubscribe(stream, owner: owner)
    }

    func submit(_ op: OpFrame) async throws -> OpOutcome {
        guard !released else { throw ControlPlaneError.stopped }
        return try await socket.client().submit(op)
    }

    func read(_ op: String, params: JSONValue, stream: String?) async throws -> ReadResultFrame {
        guard !released else { throw ControlPlaneError.stopped }
        return try await socket.client().read(op, params: params, stream: stream)
    }

    func sendSignal(_ signal: SignalFrame) async throws {
        guard !released else { throw ControlPlaneError.stopped }
        try await socket.client().sendSignal(signal)
    }

    func setPresence(active: Bool, client: String) async throws {
        guard !released else { throw ControlPlaneError.stopped }
        try await socket.client().setPresence(active: active, client: client)
    }

    func resendPending() async {
        guard !released, let client = try? await socket.client() else { return }
        await client.resendPending()
    }

    private static func finished<T>() -> AsyncStream<T> {
        let (stream, sink) = AsyncStream.makeStream(of: T.self, bufferingPolicy: .bufferingNewest(1))
        sink.finish()
        return stream
    }
}
