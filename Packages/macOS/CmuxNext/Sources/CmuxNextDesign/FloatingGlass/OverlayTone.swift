import Foundation

/// How an overlay surface tints its glass.
public nonisolated enum OverlayTone: Sendable, Equatable {
    /// The theme's glass tint (palette, hover cards, menus).
    case theme
    /// Neutral gray glass with a rim, in one ``FloatingGlassStyle`` (toasts, dialogs, prompts).
    case neutralGlass(FloatingGlassStyle)

    /// Neutral glass in the dialog style; compares equal to any neutral tone.
    public static var neutral: OverlayTone { .neutralGlass(.dialog) }

    /// The style of a neutral tone, nil for the theme tone.
    public var style: FloatingGlassStyle? {
        if case .neutralGlass(let style) = self { return style }
        return nil
    }

    /// Compared by kind: a toast's and a dialog's neutral glass are both "neutral".
    public static func == (lhs: OverlayTone, rhs: OverlayTone) -> Bool {
        (lhs.style == nil) == (rhs.style == nil)
    }
}
