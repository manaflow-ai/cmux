public import CmuxNextDesign

/// How the home page draws Allow Mac Screen on This Mac (Debug Settings `macScreen.sharingLook`,
/// Lawrence 2026-11-07: "improve this ui"). The list is the default; the others stay selectable
/// to compare them live.
public nonisolated enum MacScreenSharingLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A settings list under "This Mac": the switch, then one row per permission and the status,
    /// their glyphs in one column. A permission's detail shows only while it is missing.
    case list
    /// The switch, then one line with both permissions and one status line.
    case summary
    /// The status is the switch row's title; the permissions follow as a checklist.
    case status
    /// The page before the redesign: long details under every row.
    case classic

    public var tunableTitle: String {
        switch self {
        case .list: "List (default): permissions as aligned rows, details only when missing"
        case .summary: "Summary: both permissions on one line"
        case .status: "Status first: the status is the switch's title"
        case .classic: "Classic (before 2026-11-08)"
        }
    }
}

/// Debug Settings declarations of Mac Screen.
public nonisolated struct MacScreenTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "macScreen", title: "Mac Screen", symbol: "display", order: 48)

    /// The look of the home page's Allow Mac Screen section.
    public static let sharingLook = Tunable<MacScreenSharingLook>.choice(
        "macScreen.sharingLook", section, "This Mac section look",
        help: "How the Screen Sharing page draws Allow Mac Screen on this Mac and its permissions. Applies at once.",
        default: .list, code: "MacScreenTunables.sharingLook")

    /// Every Mac Screen tunable, for Debug Settings.
    public static var all: [TunableDescriptor] { [sharingLook.descriptor] }
}
