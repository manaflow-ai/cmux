import Foundation

/// Sendable transport boundary for the browser-level DevTools WebSocket.
protocol CDPWebSocketTransport: Sendable {
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel()
}
