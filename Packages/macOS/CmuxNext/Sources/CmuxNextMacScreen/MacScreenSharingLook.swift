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

/// How the home page draws Your Devices (Debug Settings `macScreen.devicesLook`, Leo 2026-11-16 on the
/// list: "this needs to shut up"). A row says something only when there is something to do now: a Mac
/// that can be viewed shows its name, a dot and the buttons; one that cannot shows one short word.
public nonisolated enum MacScreenDevicesLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Viewable Macs first; offline Macs folded under one "Offline" row that opens to their names.
    case quiet
    /// The same rows, offline Macs listed last as one dim line each.
    case offlineLines
    /// Only Macs that are online; one dim line counts the offline ones.
    case onlineOnly
    /// The list before 2026-11-16: status, access and an instruction on every row, disabled buttons.
    case classic

    public var tunableTitle: String {
        switch self {
        case .quiet: "Quiet (default): offline Macs folded under Offline"
        case .offlineLines: "Offline as dim lines at the end"
        case .onlineOnly: "Online only, offline counted"
        case .classic: "Classic (before 2026-11-16)"
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

    /// The look of the home page's Your Devices list.
    public static let devicesLook = Tunable<MacScreenDevicesLook>.choice(
        "macScreen.devicesLook", section, "Your Devices look",
        help: "How the Screen Sharing page lists your other Macs, offline ones above all. Applies at once.",
        default: .quiet, code: "MacScreenTunables.devicesLook")

    // The default is look A, quiet glass and picture first (Leo 2026-11-21: "our screen shared scren look slike ass");
    // `current`, B and C stay one switch away here.
    /// The look of the screen-share viewer pane.
    public static let viewerLook = Tunable<MacScreenViewerLook>.choice(
        "macScreen.viewerLook", section, "Screen viewer look",
        help: "How the screen-share viewer draws its toolbar, the area around the picture and its state cards. Applies at once.",
        default: .a, code: "MacScreenTunables.viewerLook")

    /// Every Mac Screen tunable, for Debug Settings.
    public static var all: [TunableDescriptor] { [sharingLook.descriptor, devicesLook.descriptor, viewerLook.descriptor] }
}
