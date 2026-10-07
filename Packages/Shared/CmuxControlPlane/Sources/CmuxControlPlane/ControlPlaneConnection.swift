/// One open WebSocket to a Durable Object, carrying JSON text frames.
public protocol ControlPlaneConnection: Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Throws `ControlPlaneCloseError` when the socket closes.
    func receive() async throws -> String
    func close(code: Int) async
}
