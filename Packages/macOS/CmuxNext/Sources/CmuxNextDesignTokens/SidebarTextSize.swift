public import CoreGraphics

/// `sidebar.textSize` (Lawrence msg 17752, 2026-10-30: "we also need option for sidebar text to be
/// very significantly bigger. this is how big chatgpt is by default, let's match them"): how large
/// the sidebar list's text is, on top of the app's Interface Size.
///
/// The step is added to every list size that follows the text, so a size changes them together:
/// row titles, details and tab rows, section and group headers, the leading glyph column (Home,
/// band rows, pins, workspace icons) and the row and header heights. Trailing marks (dots,
/// spinners, the close x) keep their size so the trailing column does not move. At the app's
/// compact density:
///
/// | size            | title | row | row pitch | leading glyph |
/// |-----------------|-------|-----|-----------|---------------|
/// | default         | 12 pt | 24  | 26        | 12 pt         |
/// | large           | 13 pt | 27  | 29        | 13 pt         |
/// | larger          | 14 pt | 29  | 31        | 14 pt         |
///
/// Larger matches the ChatGPT macOS app's sidebar (measured from Lawrence's screenshot at 2x:
/// 14 pt titles on a 31 pt row pitch, a ~29 pt selection fill and ~14 pt leading icons).
public nonisolated enum SidebarTextSize: String, Hashable, Sendable, CaseIterable {
    /// The sidebar's original size; the default.
    case standard = "default"
    /// One point larger text on rows 3 pt taller.
    case large
    /// The ChatGPT app's sidebar size: two points larger text on rows 5 pt taller.
    case larger

    /// Points added to the list's text sizes (titles, details, tab rows and headers).
    public var textStep: CGFloat {
        switch self {
        case .standard: 0
        case .large: 1
        case .larger: 2
        }
    }

    /// Points added to a one-line row's, a tab row's, a group header's and a section header's height.
    public var rowStep: CGFloat {
        switch self {
        case .standard: 0
        case .large: 3
        case .larger: 5
        }
    }

    /// Points added to the leading glyph column (Home's, a band row's, a pin, a workspace icon).
    public var glyphStep: CGFloat { textStep }
}
