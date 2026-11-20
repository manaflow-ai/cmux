/// How the typing indicator moves while its row leaves the transcript.
///
/// ChatKit's `CKTranscriptTypingIndicatorCell.performRemoval:` calls
/// `-[CKTypingIndicatorLayer stopPulseAnimation]` before the layout fades the
/// row: the three circles drop their breathing pulse (back to scale 1) and
/// the dots stop cycling, held at `thinkingDotOpacity` (0.45). Read from the
/// iOS 26.5 and 27.0 runtimes; identical on both.
public struct TypingIndicatorRemoval: Equatable, Sendable {
    /// Whether the circles keep breathing while the row fades.
    public var keepsPulse: Bool
    /// The opacity the dots hold while the row fades; `nil` keeps them cycling.
    public var heldDotOpacity: Double?

    public init(keepsPulse: Bool, heldDotOpacity: Double?) {
        self.keepsPulse = keepsPulse
        self.heldDotOpacity = heldDotOpacity
    }

    public static let messages = TypingIndicatorRemoval(keepsPulse: false, heldDotOpacity: 0.45)
}
