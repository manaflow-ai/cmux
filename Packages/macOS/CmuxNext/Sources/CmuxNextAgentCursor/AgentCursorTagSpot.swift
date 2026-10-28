public import CoreGraphics

/// Where one agent cursor's name tag is now (``AgentCursorLayerHost/tagSpots()``).
nonisolated public struct AgentCursorTagSpot: Sendable, Equatable {
    /// The cursor's session.
    public let session: String
    /// The tag's frame in the host layer's coordinates (y-down).
    public let frame: CGRect

    /// - Parameters:
    ///   - session: The cursor's session.
    ///   - frame: The tag's frame in the host layer.
    public init(session: String, frame: CGRect) {
        self.session = session
        self.frame = frame
    }
}
