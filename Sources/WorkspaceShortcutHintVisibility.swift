import Foundation

/// Decides whether a sidebar workspace row shows its ⌘-number hint, and at what
/// opacity. Pure value logic so the interplay between the modifier-hold hint,
/// the persistent "always show workspace numbers" preference, and the hover
/// close button can be unit-tested without a live sidebar.
struct WorkspaceShortcutHintVisibility: Equatable {
    let isVisible: Bool
    let opacity: Double

    /// - Parameters:
    ///   - modifierHintActive: the ⌘-hold hint is active (modifier held and the
    ///     user toggle on) or the debug/UI-test always-on override is set. These
    ///     always show the number at full strength.
    ///   - alwaysShowsNumbers: the persistent "always show workspace numbers"
    ///     sidebar preference.
    ///   - hasLabel: a shortcut digit exists for this row (⌘1–⌘9).
    ///   - closeButtonVisible: the hover close button occupies the top-trailing
    ///     slot; the persistent number yields it so the two never overlap.
    ///   - dimmedOpacity: opacity for the persistent (non-modifier) number.
    static func resolve(
        modifierHintActive: Bool,
        alwaysShowsNumbers: Bool,
        hasLabel: Bool,
        closeButtonVisible: Bool,
        dimmedOpacity: Double = 0.4
    ) -> WorkspaceShortcutHintVisibility {
        guard hasLabel else {
            return WorkspaceShortcutHintVisibility(isVisible: false, opacity: 1.0)
        }
        if modifierHintActive {
            return WorkspaceShortcutHintVisibility(isVisible: true, opacity: 1.0)
        }
        guard alwaysShowsNumbers, !closeButtonVisible else {
            return WorkspaceShortcutHintVisibility(isVisible: false, opacity: 1.0)
        }
        return WorkspaceShortcutHintVisibility(isVisible: true, opacity: dimmedOpacity)
    }
}
