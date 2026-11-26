import Foundation

/// Decides when the palette overlay container should be re-promoted above
/// sibling overlay views in the window's overlay container: exactly on the
/// hidden-to-visible transition, so an already-visible palette is not
/// reshuffled on every state update.
public struct CommandPaletteOverlayPromotionPolicy: Sendable {
    /// Whether the overlay was visible before this update.
    public let previouslyVisible: Bool
    /// Whether the overlay is visible after this update.
    public let isVisible: Bool

    /// Captures the visibility transition to evaluate.
    public init(previouslyVisible: Bool, isVisible: Bool) {
        self.previouslyVisible = previouslyVisible
        self.isVisible = isVisible
    }

    /// Whether the overlay should be promoted above its siblings.
    public var shouldPromote: Bool {
        isVisible && !previouslyVisible
    }
}
