public import CmuxNextDesign

/// How the space switcher marks a space another window shows (`sidebar.spaceSwitcher`, design/spaces.md
/// "The switcher (PR 3)"). Leo 2026-10-29: "there's also other ergo wrt new windows being like new spaces,
/// incognito spaces, etc... this could legit make our thing more useful than chrome by having windows be
/// switchable in this way". Every style keeps today's dots strip; `plain` is the strip as it was.
public nonisolated enum SpaceSwitcherStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A thin ring around the mark of a space another window shows. Click: Go to Window or Move Here;
    /// Option-click: go to that window. The pick (design/spaces.md).
    case ring
    /// A small window glyph at the mark's corner instead of the ring (the named chips' marker on the dots).
    case glyph
    /// Arc's space menu: the current space's mark opens every space with its window, Move Here / Go to
    /// Window on the ones another window shows, and New Space / New Incognito Space at the end.
    case menu
    /// Today's strip: no marker, a click switches this window.
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
        help: "How the spaces strip shows a space another window shows: a ring, a window glyph, or Arc's space menu from the current space; plain is the strip without a marker.",
        default: .ring, code: "SpaceSwitcherStyle.tunable")

    /// Whether the strip marks and offers another window's spaces at all.
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
