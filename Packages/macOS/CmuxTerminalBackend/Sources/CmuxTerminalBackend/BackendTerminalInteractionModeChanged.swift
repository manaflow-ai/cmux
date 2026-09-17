/// One monotonic parser-owned interaction-mode transition for a terminal incarnation.
public struct BackendTerminalInteractionModeChanged: Codable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let terminalEpoch: UInt64
    public let interactionRevision: UInt64
    public let mouseTracking: Bool

    public init(
        surfaceID: SurfaceID,
        terminalEpoch: UInt64,
        interactionRevision: UInt64,
        mouseTracking: Bool
    ) {
        self.surfaceID = surfaceID
        self.terminalEpoch = terminalEpoch
        self.interactionRevision = interactionRevision
        self.mouseTracking = mouseTracking
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case terminalEpoch = "terminal_epoch"
        case interactionRevision = "interaction_revision"
        case mouseTracking = "mouse_tracking"
    }
}
