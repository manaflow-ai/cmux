/// `sidebar.groupHeader.background` (Lawrence 2026-11-05: "invariant: groups must always have a visible bg
/// color, groups should support both glassy and solid bgs too"): how a sidebar group header's background
/// draws. `glass`, `solid` and `auto` keep the background visible against the sidebar (`GroupBackground`);
/// `folder`, the default since David Beyer's feedback (2026-11-20: groups should be plain folders, with all
/// threads in one place), and `sections` draw none.
public nonisolated enum SidebarGroupBackgroundStyle: String, Hashable, Sendable, CaseIterable {
    /// A plain folder, the default: a folder glyph and the name in the theme's primary ink, no fill, no rim and no
    /// members' line; the members sit one indent step in under it, as a file list's folder holds its files.
    case folder
    /// cmux's own group look (Leo's tinted glass, 2026-11-05; Debug `sidebar.groupGlass` may set it solid).
    case auto
    /// A translucent fill the window's glass shows through, edged with a hairline rim.
    case glass
    /// An opaque fill.
    case solid
    /// No background: each group draws as a plain section heading, its name in the quiet ink with no fill and no
    /// members' line (Leo 2026-11-05: "they have these sections ... maybe we can also have an option to have that").
    case sections

    /// Whether the background draws as glass, given whether cmux's own group look (`appLooksGlassy`) is glass.
    ///
    /// - Parameter appLooksGlassy: cmux's own group look is glass (Debug `sidebar.groupGlass` is not solid).
    /// - Returns: True for the glass look, false for the solid one and the looks with no background.
    public func drawsGlass(appLooksGlassy: Bool) -> Bool {
        switch self {
        case .auto: appLooksGlassy
        case .glass: true
        case .solid, .sections, .folder: false
        }
    }

    /// Whether a group draws a background (a fill, a rim and its members' line) at all: false for `folder` and
    /// `sections`.
    public var drawsBackground: Bool { self != .sections && self != .folder }

    /// Whether a group's members sit one indent step in from its header, so the tree reads with no line beside
    /// them: true only for `folder`. Every other look keeps a top-level group's members on the loose rows' x (Leo
    /// 2026-10-21, #23975), where the header's band and the members' line mark the group.
    public var indentsMembers: Bool { self == .folder }
}
