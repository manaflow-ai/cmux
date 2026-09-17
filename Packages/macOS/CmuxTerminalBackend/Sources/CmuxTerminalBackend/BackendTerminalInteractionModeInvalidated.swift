/// Fatal interaction-revision invalidation for one terminal incarnation.
public struct BackendTerminalInteractionModeInvalidated: Codable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let terminalEpoch: UInt64
    public let reason: String

    public init(surfaceID: SurfaceID, terminalEpoch: UInt64, reason: String) {
        self.surfaceID = surfaceID
        self.terminalEpoch = terminalEpoch
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case terminalEpoch = "terminal_epoch"
        case reason
    }
}
