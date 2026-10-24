public import AppKit

/// A menu row's own view that draws in the menu's theme scope:
/// `themeRows(in:)` hands it the scope of the view that was right-clicked.
public protocol ThemedMenuItemView: NSView {
    /// Draws in `scope` from now on.
    func adoptMenuScope(_ scope: ThemeScope)
}
