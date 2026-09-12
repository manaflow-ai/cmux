import Foundation

/// Carries framed CDP messages between one connection and Chromium.
protocol ChromiumCDPTransport: Actor {
    /// Prepares the transport to send and receive messages.
    func connect() async throws

    /// Returns the single ordered stream of decoded transport frames.
    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>>

    /// Sends one complete JSON CDP message.
    func send(_ data: Data) async throws

    /// Closes the transport and finishes its message stream.
    func close()
}
