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

/// Debug Settings declarations of the feed panel. The App adds `all` to its
/// tunable catalog when it links this module.
public nonisolated enum FeedTunables {
    public static let section = TunableSection(id: "feed", title: "Feed", symbol: "tray.full", order: 42)

    public static let layout = Tunable<FeedLayout>.choice(
        "feed.layout", section, "Layout", help: "Prototype layout of the feed panel. Switches live.",
        default: .list, code: "FeedTunables.layout")

    public static let rowHeight = Tunable<Double>.number(
        "feed.rowHeight", section, "Row height", help: "Height of a one-line row (notices, inbox).",
        default: 30, range: 22...48, step: 1, unit: .points, code: "FeedTunables.rowHeight")

    public static var all: [TunableDescriptor] {
        [layout.descriptor, rowHeight.descriptor]
    }
}
