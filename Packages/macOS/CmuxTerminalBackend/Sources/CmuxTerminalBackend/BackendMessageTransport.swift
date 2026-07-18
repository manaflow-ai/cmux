public import Foundation

/// Full-duplex message framing used by the backend protocol client.
public protocol BackendMessageTransport: Sendable {
    /// Opens the transport.
    ///
    /// - Throws: A transport-specific connection error.
    func connect() async throws

    /// Sends one complete unframed protocol message.
    ///
    /// - Parameter message: The encoded protocol message.
    /// - Throws: A transport or framing error.
    func send(_ message: Data) async throws

    /// Receives one complete unframed protocol message.
    ///
    /// - Returns: The encoded protocol message.
    /// - Throws: A transport or framing error.
    func receive() async throws -> Data

    /// Closes the transport and cancels outstanding transport work.
    func close() async
}
