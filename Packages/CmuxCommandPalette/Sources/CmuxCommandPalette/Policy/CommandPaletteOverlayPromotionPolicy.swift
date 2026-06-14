import Foundation

/// Decides when the palette overlay container should be re-promoted above
/// sibling overlay views in the window's overlay container: exactly on the
/// hidden-to-visible transition, so an already-visible palette is not
/// reshuffled on every state update.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum CommandPaletteOverlayPromotionPolicy {
    /// Whether the overlay should be promoted above its siblings.
    public static func shouldPromote(previouslyVisible: Bool, isVisible: Bool) -> Bool {
        isVisible && !previouslyVisible
    }
}
