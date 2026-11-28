// Follows schemas/design-scale/design-scale.json `surfaces`: change the schema and this copy together.
// scripts/cmux-next/check-surface-roles.py checks these numbers against the schema.

/// The content surface levels of a page (design/chat-surfaces.md; Lawrence 2026-11-19: "bgs are
/// different, we need to make all bgs consistent, from first principles"): what sits in the page
/// (the transcript's cards, code blocks, chips) is the page's ink, its text color, laid over clear at a
/// fixed share. Never the page color, black, white or a glass veil: ink over clear keeps the same step
/// over an opaque page, glass or a wallpaper, flips with light and dark on its own and lets the art show
/// through. Floating surfaces (menus, toasts, the composer) are glass, never these. The web reads the
/// same numbers as `--ds-surface-*`; the iPhone chat draws them with `CmuxMobileContentSurface`.
public nonisolated enum ContentSurfaceLevel: String, CaseIterable, Sendable {
    /// A container of content in the page: the transcript's tool, edit, error and permission cards, plans, code blocks, tool output, the subagent card.
    case card
    /// A piece inside a card or inline in text: an icon tile, inline code, a chip, a key cap, a filled secondary control.
    case inset
    /// A control in the page under the pointer: half way from clear to pressed.
    case hover
    /// The outline of a secondary button at rest; its hover and press take the hover and pressed roles.
    case control

    /// The ink's share of the fill, 0...1; 0 draws no fill.
    public var fill: Double {
        switch self {
        case .card: return 0.04
        case .inset: return 0.08
        case .hover: return 0.06
        case .control: return 0
        }
    }

    /// The ink's share of the 1 px line, 0...1; 0 draws no line.
    public var line: Double {
        switch self {
        case .card: return 0.1
        case .inset: return 0
        case .hover: return 0
        case .control: return 0.16
        }
    }

    /// The level's fill: `ink` (the page's text color) at ``fill``.
    public func fill(ink: ThemeRGB) -> ThemeRGB { ink.withAlpha(ink.alpha * fill) }

    /// The level's line: `ink` at ``line``.
    public func line(ink: ThemeRGB) -> ThemeRGB { ink.withAlpha(ink.alpha * line) }
}
