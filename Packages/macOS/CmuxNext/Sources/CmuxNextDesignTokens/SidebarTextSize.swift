public import CoreGraphics

/// `sidebar.textSize` (Lawrence msg 17752, 2026-10-30: "we also need option for sidebar text to be
/// very significantly bigger. this is how big chatgpt is by default, let's match them"): how large
/// the sidebar list's text is, on top of the app's Interface Size.
///
/// Small | Medium | Large (2026-10-30: "default is ChatGPT size. the one that is current is small..
/// small | medium | large"). Small is the Codex desktop sidebar the list's base tokens draw
/// (https://github.com/manaflow-ai/cmux/issues/28793): 13 pt titles at weight 430 on a 30 pt row
/// pitch. Medium, the default, is the ChatGPT macOS app's sidebar (measured from Lawrence's
/// screenshot at 2x: 14 pt titles on a 31 pt row pitch, ~14 pt leading icons). Large is a step past it.
///
/// The step is added to every list size that follows the text, so a size changes them together:
/// row titles, details and tab rows, section and group headers, the leading glyph column (Home,
/// band rows, pins, workspace icons) and the row and header heights. Trailing marks (dots,
/// spinners, the close x) keep their size so the trailing column does not move. At the app's
/// compact density:
///
/// | size            | title | detail | row | row pitch | leading glyph |
/// |-----------------|-------|--------|-----|-----------|---------------|
/// | small           | 13 pt | 12 pt  | 28  | 30        | 12 pt         |
/// | medium, default | 14 pt | 13 pt  | 29  | 31        | 14 pt         |
/// | large           | 15 pt | 14 pt  | 32  | 34        | 15 pt         |
public nonisolated enum SidebarTextSize: String, Hashable, Sendable, CaseIterable {
    /// The Codex desktop sidebar's size: the list's base tokens.
    case small
    /// The ChatGPT app's sidebar size; the default.
    case medium
    /// A step past the ChatGPT size.
    case large

    /// The size a `sidebar.textSize` value names, including the values of the first three-step
    /// setting (2026-10-30): "default" and "larger" (the ChatGPT size) read as Medium.
    public init?(setting value: String) {
        switch value {
        case "default", "larger": self = .medium
        default: self.init(rawValue: value)
        }
    }

    /// Points added to the list's text sizes (titles, details, tab rows and headers).
    public var textStep: CGFloat {
        switch self {
        case .small: 0
        case .medium: 1
        case .large: 2
        }
    }

    /// Points added to a one-line row's, a tab row's, a group header's and a section header's height.
    public var rowStep: CGFloat {
        switch self {
        case .small: 0
        case .medium: 1
        case .large: 4
        }
    }

    /// Points added to the leading glyph column (Home's, a band row's, a pin, a workspace icon).
    public var glyphStep: CGFloat {
        switch self {
        case .small: 0
        case .medium: 2
        case .large: 3
        }
    }
}
