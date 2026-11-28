public import Foundation

/// One control connection; its lifetime never owns an IROH peer connection.
public protocol V2ControlSocket: Sendable {
    /// Sends one UTF-8 JSON frame.
    /// - Parameter data: A generated versioned request encoded as JSON.
    /// - Throws: A transport error if the frame cannot be sent.
    func send(_ data: Data) async throws
    /// Waits for one frame with no receive-idle timeout.
    /// - Returns: UTF-8 JSON bytes from the backend.
    /// - Throws: A transport error when the socket fails or closes.
    func receive() async throws -> Data
    /// Sends a native WebSocket ping; Cloudflare responds without waking the object.
    /// - Throws: A transport error if the protocol exchange fails.
    func ping() async throws
    /// Closes this control socket and releases its pending receive.
    func close() async
}
