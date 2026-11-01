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

/// Another open window that shows a space (`SpaceSwitcherLogic.shownElsewhere`).
public nonisolated struct SpaceElsewhere: Hashable, Sendable {
    /// The window showing the space (the frontmost one when several do).
    public var windowID: String
    /// That window is incognito: the space never moves between it and a normal window.
    public var incognito: Bool

    public init(windowID: String, incognito: Bool) {
        self.windowID = windowID
        self.incognito = incognito
    }
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

/// What the strip offers on a space another window shows.
public nonisolated enum SpaceWindowChoice: Hashable, Sendable {
    /// Bring the window that shows it to the front (`SidebarIntent.goToSpaceWindow`).
    case goToWindow
    /// Move the space's workspaces into this window and show it here (`space.bringHere`).
    case moveHere
}

/// What a click on a space mark does (`SpaceSwitcherLogic.click`).
public nonisolated enum SpaceClick: Hashable, Sendable {
    /// Nothing (the current space under a style with no menu on it).
    case none
    /// Show the space in this window (today's click).
    case switchHere
    /// Bring the window that shows it to the front.
    case goToWindow
    /// Offer these choices in a menu at the mark.
    case offer([SpaceWindowChoice])
    /// Open the whole space menu (the `menu` style's current space).
    case spaceMenu
}

/// The pure rules of the switcher's window marks: which spaces other windows show, and what a click offers.
public nonisolated enum SpaceSwitcherLogic {
    /// The spaces open windows other than `here` show, each with the frontmost such window. `windows` runs
    /// front to back. A space this window shows itself is still listed when another window shows it too.
    public static func shownElsewhere(_ windows: [SpaceWindowShowing], here: String) -> [ProfileKey: SpaceElsewhere] {
        var result: [ProfileKey: SpaceElsewhere] = [:]
        for window in windows where window.windowID != here && result[window.space] == nil {
            result[window.space] = SpaceElsewhere(windowID: window.windowID, incognito: window.incognito)
        }
        return result
    }

    /// The choices for a space another window shows. Move Here never joins incognito and normal content
    /// (design/spaces.md "Incognito"): neither from an incognito window nor into one.
    public static func choices(for elsewhere: SpaceElsewhere, hereIsIncognito: Bool) -> [SpaceWindowChoice] {
        elsewhere.incognito || hereIsIncognito ? [.goToWindow] : [.goToWindow, .moveHere]
    }

    /// What a click on `space` does in a window showing `active`, under `style`. `option` is Option held.
    public static func click(_ space: ProfileKey, active: ProfileKey?, elsewhere: SpaceElsewhere?, hereIsIncognito: Bool,
                             style: SpaceSwitcherStyle, option: Bool) -> SpaceClick {
        if space == active, style == .menu { return .spaceMenu }
        // This window's own space is ringed too when another window also shows it: the same choices.
        guard style.marksOtherWindows, let elsewhere else { return space == active ? .none : .switchHere }
        if option { return .goToWindow }
        return .offer(choices(for: elsewhere, hereIsIncognito: hereIsIncognito))
    }
}
