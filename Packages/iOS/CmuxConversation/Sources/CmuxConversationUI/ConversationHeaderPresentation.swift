#if canImport(UIKit)
import UIKit

/// Presentation hooks for a host that uses the conversation outside Messages.
/// The package continues to own header layout, controls and transcript insets.
public struct ConversationHeaderPresentation {
    public enum ScrollEdge: Sendable {
        /// Preserve the package's platform-specific Messages wash/blur.
        case messages
        /// Use UIKit's soft scroll edge across the entire header on iOS 26+.
        case system
    }

    public var scrollEdge: ScrollEdge
    /// Space below the header before the transcript starts. Nil preserves
    /// Messages' portrait/landscape spacing. Negative values are clamped to zero.
    public var transcriptTopSpacing: CGFloat?
    public var actionAccessibilityLabel: String?
    public var avatarAccessibilityLabel: String?
    public var avatarAccessibilityHint: String?

    public init(
        scrollEdge: ScrollEdge = .messages,
        transcriptTopSpacing: CGFloat? = nil,
        actionAccessibilityLabel: String? = nil,
        avatarAccessibilityLabel: String? = nil,
        avatarAccessibilityHint: String? = nil
    ) {
        self.scrollEdge = scrollEdge
        self.transcriptTopSpacing = transcriptTopSpacing
        self.actionAccessibilityLabel = actionAccessibilityLabel
        self.avatarAccessibilityLabel = avatarAccessibilityLabel
        self.avatarAccessibilityHint = avatarAccessibilityHint
    }
}
#endif
