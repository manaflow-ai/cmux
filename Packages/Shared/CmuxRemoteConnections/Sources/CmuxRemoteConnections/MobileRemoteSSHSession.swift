public import Foundation

/// An authenticated SSH session consumed by terminal and protocol clients.
public protocol MobileRemoteSSHSession: Sendable {
    /// Supplies terminal bytes with bounded buffering in the engine implementation.
    /// - Returns: Output until EOF or failure.
    func output() -> AsyncThrowingStream<Data, any Error>
    /// Sends raw terminal input without shell interpolation.
    /// - Parameter data: Input bytes.
    /// - Throws: Transport, cancellation, or closed-session errors.
    func sendInput(_ data: Data) async throws
    /// Requests remote PTY geometry.
    /// - Parameters:
    ///   - columns: Positive terminal width.
    ///   - rows: Positive terminal height.
    /// - Throws: Invalid geometry or transport errors.
    func resize(columns: Int, rows: Int) async throws
    /// Idempotently closes channels and releases native engine state.
    func close() async
}
