public import CMUXMobileCore

/// One independently cancellable terminal lane for a single mounted surface.
public protocol MobileTerminalLaneConnection: Sendable {
    /// Returns the next complete sequence-aware output frame.
    func receiveOutput() async throws -> MobileTerminalLaneOutputFrame?
    /// Sends one exact terminal-input operation.
    func sendInput(_ input: String) async throws
    /// Aborts both stream halves.
    func close() async
}

/// Opens a terminal lane on the already-admitted peer connection.
public typealias MobileTerminalLaneProvider = @Sendable (
    _ request: CmxByteTransportRequest,
    _ surfaceID: String,
    _ cursor: UInt64?
) async throws -> any MobileTerminalLaneConnection
