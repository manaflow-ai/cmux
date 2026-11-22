public import CmuxNextDesign

/// Feed panel prototypes (`feed.layout` in Debug Settings, DEV and NIGHTLY
/// only). Release builds use the variant Lawrence picks after dogfood.
public nonisolated enum FeedLayout: String, Sendable, CaseIterable, TunableChoice {
    /// One chronological list; open requests pinned on top with inline answers.
    case list
    /// Grouped list (Needs you, Today, Earlier) and the selected item's detail.
    case inbox

    public var tunableTitle: String {
        switch self {
        case .list: "List (requests pinned, inline answers)"
        case .inbox: "Inbox (grouped list + detail)"
        }
    }
}

/// The menu bar prototype (`feed.menubar`).
public nonisolated enum FeedMenubarStyle: String, Sendable, CaseIterable, TunableChoice {
    case off
    /// Status item with the open request count; a popover of open requests.
    case compact

    public var tunableTitle: String {
        switch self {
        case .off: "Off"
        case .compact: "Compact (open requests only)"
        }
    }
}

/// Debug Settings declarations of the feed panel. The App adds `all` to its
/// tunable catalog when it links this module.
public nonisolated enum FeedTunables {
    public static let section = TunableSection(id: "feed", title: "Feed", symbol: "tray.full", order: 42)

    public static let layout = Tunable<FeedLayout>.choice(
        "feed.layout", section, "Layout", help: "Prototype layout of the feed panel. Switches live.",
        default: .list, code: "FeedTunables.layout")

    public static let menubar = Tunable<FeedMenubarStyle>.choice(
        "feed.menubar", section, "Menu bar", help: "Prototype menu bar item for open requests.",
        default: .off, code: "FeedTunables.menubar")

    public static let rowHeight = Tunable<Double>.number(
        "feed.rowHeight", section, "Row height", help: "Height of a one-line row (notices, inbox, menu bar).",
        default: 30, range: 22...48, step: 1, unit: .points, code: "FeedTunables.rowHeight")

    public static let menubarWidth = Tunable<Double>.number(
        "feed.menubarWidth", section, "Menu bar popover width", help: "Width of the menu bar popover.",
        default: 360, range: 300...480, step: 4, unit: .points, code: "FeedTunables.menubarWidth")

    public static var all: [TunableDescriptor] {
        [layout.descriptor, menubar.descriptor, rowHeight.descriptor, menubarWidth.descriptor]
    }
}
