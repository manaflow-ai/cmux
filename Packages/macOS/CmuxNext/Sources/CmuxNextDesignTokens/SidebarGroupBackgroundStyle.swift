/// `sidebar.groupHeader.background` (Lawrence 2026-11-05: "invariant: groups must always have a visible bg
/// color, groups should support both glassy and solid bgs too"): how a sidebar group header's background
/// draws. Automatic, the default, keeps the header band visible against the sidebar (`GroupBackground`).
public nonisolated enum SidebarGroupBackgroundStyle: String, Hashable, Sendable, CaseIterable {
    /// A plain folder: a folder glyph and the name in the theme's primary ink, no fill, no rim and no
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
    /// Chromium's tab-group look (Leo 2026-11-22: "Chromium's tab groups, a colored group chip/border/rail around
    /// member tabs with NO indent"): the header is a slim chip in the group's color hugging the name, a colored rail
    /// runs down the left edge of the members, and the members keep the loose rows' x. A prototype look, opt-in.
    case chip
    /// The plain folder drawn as a tree (Leo 2026-11-22: "we might as well push harder into what we believe"): the
    /// folder glyph and indent of `folder`, with one thin guide line under the glyph tying the members to their
    /// folder, in the group's color. A prototype look, opt-in.
    case tree
    /// One rounded tinted card around the whole group, header and members (Leo 2026-11-22: "push harder"): the
    /// group's color is the card's wash, the members keep the loose rows' x inside it, and a collapsed group is the
    /// card's header alone. A prototype look, opt-in.
    case card

    /// Whether the background draws as glass, given whether cmux's own group look (`appLooksGlassy`) is glass.
    ///
    /// - Parameter appLooksGlassy: cmux's own group look is glass (Debug `sidebar.groupGlass` is not solid).
    /// - Returns: True for the glass look, false for the solid one and the looks with no background.
    public func drawsGlass(appLooksGlassy: Bool) -> Bool {
        switch self {
        case .auto: appLooksGlassy
        case .glass: true
        case .solid, .sections, .folder, .chip, .tree, .card: false
        }
    }

    /// Whether a group header draws a background band (a fill, a rim) of its own: true only for `auto`, `glass` and
    /// `solid`. `folder`, `sections`, `chip`, `tree` and `card` draw a plain row (`chip` a slim chip on it, `card` a
    /// card behind the whole group, see ``drawsMembersMark``).
    public var drawsBackground: Bool { self == .auto || self == .glass || self == .solid }

    /// Whether the group draws a mark beside or behind its members (a rail, a guide line or a card): false for
    /// `folder` and `sections`, whose members carry no chrome.
    public var drawsMembersMark: Bool { self != .sections && self != .folder }

    /// Whether a group's members sit one indent step in from its header, so the tree reads with no line beside
    /// them: true for `folder` and `tree`. Every other look keeps a top-level group's members on the loose rows' x (Leo
    /// 2026-10-21, #23975), where the header's band and the members' line mark the group.
    public var indentsMembers: Bool { self == .folder || self == .tree }

    /// Whether a header without an icon of its own leads with the icon pack's folder glyph: `folder` and `tree`.
    public var leadsWithFolder: Bool { self == .folder || self == .tree }

    /// Whether every group, colored or not, draws as one rounded block around its header and members: `card`.
    public var drawsCard: Bool { self == .card }

    /// Whether a tab strip's group chips take the look: false for the looks only a sidebar has (`folder`, `chip`,
    /// `tree`, `card`), whose chips keep the automatic look.
    public var drawsOnTabStrip: Bool { !(self == .folder || self == .chip || self == .tree || self == .card) }
}
