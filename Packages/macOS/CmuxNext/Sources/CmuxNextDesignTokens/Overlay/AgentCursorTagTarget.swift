public import CoreGraphics

/// One agent cursor name tag a person can click (user, 2026-10-20: the tag
/// names who drives and where, and a click goes there).
nonisolated public struct AgentCursorTagTarget: Sendable, Equatable {
    /// The cursor's session; ``AgentCursorTagSource/pressAgentCursorTag(_:)`` gets it back.
    public var id: String
    /// The tag's frame in `WindowOverlayHost.agentCursorLayer` coordinates (y-down).
    public var frame: CGRect
    /// The tag's text ("a201 · cursor-gallery").
    public var label: String
    /// The tooltip and VoiceOver help ("Go to cursor-gallery").
    public var help: String
    /// What VoiceOver reads for the tag; the label when nil.
    public var accessibilityLabel: String?

    /// - Parameters:
    ///   - id: The cursor's session.
    ///   - frame: The tag's frame in the cursor layer (y-down).
    ///   - label: The tag's text.
    ///   - help: The tooltip and VoiceOver help.
    ///   - accessibilityLabel: What VoiceOver reads; nil reads `label`.
    public init(id: String, frame: CGRect, label: String, help: String, accessibilityLabel: String? = nil) {
        self.id = id
        self.frame = frame
        self.label = label
        self.help = help
        self.accessibilityLabel = accessibilityLabel
    }
}
