public import CmuxNextDesign

/// How the space switcher marks a space another window shows (`sidebar.spaceSwitcher`, design/spaces.md
/// "The switcher (PR 3)"). Leo 2026-10-29: "there's also other ergo wrt new windows being like new spaces,
/// incognito spaces, etc... this could legit make our thing more useful than chrome by having windows be
/// switchable in this way". Every style keeps today's dots strip and the same click: the space comes into this
/// window (`SpaceSwitcherLogic.click`), and its tooltip is the space's name alone (Leo 2026-11-11: "why does it
/// say default in another window?"). The style only draws the hint.
public nonisolated enum SpaceSwitcherStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A thin ring around the mark of a space another window shows: a click brings it here. The pick (design/spaces.md).
    case ring
    /// A small window glyph at the mark's corner instead of the ring (the named chips' marker on the dots).
    case glyph
    /// a space menu: the current space's mark opens every space by name (a pick brings it here), and New Space /
    /// New Incognito Space at the end.
    case menu
    /// No marker: every space looks alike, wherever it is shown.
    case plain

    public var tunableTitle: String {
        switch self {
        case .ring: "Dots, ring on another window's space"
        case .glyph: "Dots, window glyph on another window's space"
        case .menu: "Dots, current space opens the space menu"
        case .plain: "Dots only (no window marker)"
        }
    }

    public static let tunable = Tunable<SpaceSwitcherStyle>.choice(
        "sidebar.spaceSwitcher", .sidebar, "Space switcher",
        help: "How the spaces strip hints at a space another window shows: a ring, a window glyph, or a space menu from the current space; plain draws no hint. A click always brings the space into this window.",
        default: .ring, code: "SpaceSwitcherStyle.tunable")

    /// Whether the strip draws a hint on another window's spaces (the click is the same in every style).
    public var marksOtherWindows: Bool { self != .plain }
}

/// One open window and the space it shows, front to back (`SpaceSwitcherLogic.shownElsewhere`).
public nonisolated struct SpaceWindowShowing: Hashable, Sendable {
    public var windowID: String
    public var space: ProfileKey
    public var incognito: Bool

    public init(windowID: String, space: ProfileKey, incognito: Bool = false) {
        self.windowID = windowID
        self.space = space
        self.incognito = incognito
    }
}
