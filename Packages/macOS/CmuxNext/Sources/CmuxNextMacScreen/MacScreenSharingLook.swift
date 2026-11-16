public import CmuxNextDesign

/// How the home page draws Allow Mac Screen on This Mac (Debug Settings `macScreen.sharingLook`,
/// Lawrence 2026-11-07: "improve this ui"). Simple is the default (Leo 2026-11-15: "i hate the
/// "you approve each one" and i hate the fucking appearance of the whole allow deny etc etc it's too
/// many fucking steps"); the others stay selectable to compare them live.
public nonisolated enum MacScreenSharingLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// One switch (its detail is the status), a Connected row with Stop while a device is connected,
    /// and the macOS permissions as one Grant Access step while one is missing.
    case simple
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
        case .simple: "Simple (default): one switch, Connected with Stop, one Grant Access step"
        case .list: "List: permissions as aligned rows, details only when missing"
        case .summary: "Summary: both permissions on one line"
        case .status: "Status first: the status is the switch's title"
        case .classic: "Classic (before 2026-11-08)"
        }
    }
}

/// How Your Devices draws each of the user's other devices (Debug Settings `macScreen.devicesLook`).
/// Every look has one action, Connect (Full Control), and a menu for View Only and the rest; a device
/// that can't connect says why in a line that wraps, with no disabled buttons.
public nonisolated enum MacScreenDevicesLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Connect, then a More (…) menu, at the row's trailing edge.
    case connect
    /// Connect with its menu's chevron beside it, one split control.
    case split
    /// Online devices first with Connect, offline ones under their own header without actions.
    case grouped

    public var tunableTitle: String {
        switch self {
        case .connect: "Connect and More (default)"
        case .split: "Split Connect button"
        case .grouped: "Online first, offline grouped"
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
        default: .simple, code: "MacScreenTunables.sharingLook")

    /// The look of the home page's Your Devices rows.
    public static let devicesLook = Tunable<MacScreenDevicesLook>.choice(
        "macScreen.devicesLook", section, "Your Devices row look",
        help: "How the Screen Sharing page draws your other devices: one Connect action and a menu. Applies at once.",
        default: .connect, code: "MacScreenTunables.devicesLook")

    /// Every Mac Screen tunable, for Debug Settings.
    public static var all: [TunableDescriptor] { [sharingLook.descriptor, devicesLook.descriptor] }
}
