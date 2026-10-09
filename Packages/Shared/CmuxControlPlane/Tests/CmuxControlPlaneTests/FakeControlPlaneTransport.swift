import CmuxControlPlane
import Foundation

/// An in-memory control-plane server for tests: each `connect` yields a `FakeServerSocket`
/// the test drives (read the client's frames, answer, close with a code).
final class FakeControlPlaneTransport: ControlPlaneTransport, @unchecked Sendable {
    let sockets: AsyncStream<FakeServerSocket>
    private let sink: AsyncStream<FakeServerSocket>.Continuation
    private let lock = NSLock()
    private var _protocols: [[String]] = []
    /// Refuse this many connects before accepting (reconnect tests).
    var refusals = 0

    init() {
        (sockets, sink) = AsyncStream.makeStream(of: FakeServerSocket.self, bufferingPolicy: .unbounded)
    }

    var protocolsSeen: [[String]] { lock.withLock { _protocols } }

    func connect(url: URL, protocols: [String]) async throws -> any ControlPlaneConnection {
        let refuse: Bool = lock.withLock {
            _protocols.append(protocols)
            if refusals > 0 { refusals -= 1; return true }
            return false
        }
        if refuse { throw URLError(.cannotConnectToHost) }
        let socket = FakeServerSocket()
        sink.yield(socket)
        return socket.clientSide
    }
}
