public import CMUXMobileCore
public import Foundation

/// One simulator-stream v2 lane: raw framed wire bytes in both directions.
/// Message framing and codec live in `CmuxSimulatorStreamKit`; this seam is
/// deliberately byte-level so the transport package stays codec-free.
public protocol MobileSimulatorStreamLaneConnection: Sendable {
    /// Returns the next received chunk, or nil after a clean host finish.
    func receive() async throws -> Data?
    /// Sends one complete framed wire message.
    func send(_ data: Data) async throws
    /// Aborts both stream halves.
    func close() async
}

/// Opens a simulator-stream lane on the already-admitted peer connection.
public typealias MobileSimulatorStreamLaneProvider = @Sendable (
    _ request: CmxByteTransportRequest,
    _ panelID: String
) async throws -> any MobileSimulatorStreamLaneConnection
