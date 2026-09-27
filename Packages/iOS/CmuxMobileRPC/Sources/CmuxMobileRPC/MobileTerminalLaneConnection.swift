public import CMUXMobileCore

/// One independently cancellable terminal lane for a single mounted surface.
public protocol MobileTerminalLaneConnection: Sendable {
    /// Returns the next complete sequence-aware output frame.
    func receiveOutput() async throws -> MobileTerminalLaneOutputFrame?
    /// Sends one exact terminal-input operation.
    func sendInput(_ input: String) async throws
    /// Sends an opaque marker when the host supports latency metadata.
    func sendInput(_ input: String, sequence: UInt64?) async throws
    /// Aborts both stream halves.
    func close() async
}

/// Opens a terminal lane on the already-admitted peer connection.
public typealias MobileTerminalLaneProvider = @Sendable (
    _ request: CmxByteTransportRequest,
    _ surfaceID: String,
    _ cursor: UInt64?
) async throws -> any MobileTerminalLaneConnection

extension MobileTerminalLaneConnection {
    public func sendInput(_ input: String, sequence: UInt64?) async throws {
        try await sendInput(input)
    }
}
