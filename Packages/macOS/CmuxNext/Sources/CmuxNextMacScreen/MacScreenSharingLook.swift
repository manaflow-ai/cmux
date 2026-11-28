public import CmuxNextDesign

/// How the home page draws Allow Mac Screen on This Mac (Debug Settings `macScreen.sharingLook`,
/// Lawrence 2026-11-07: "improve this ui"). Simple is the default (Leo 2026-11-16: "i hate the
/// "you approve each one" and i hate the ... appearance of the whole allow deny etc etc it's too
/// many ... steps"); the others stay selectable to compare them live.
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
        default: .simple, code: "MacScreenTunables.sharingLook")

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

    /// Where the viewer shows the stream's rate and quality (D10: an ultra session shows the link it spends).
    public static let qualityReadout = Tunable<MacScreenQualityReadout>.choice(
        "macScreen.qualityReadout", section, "Screen viewer quality readout",
        help: "Where the screen-share viewer shows the stream's rate, frames, round trip, loss and encode time. Applies at once.",
        default: .inline, code: "MacScreenTunables.qualityReadout")

    /// How the floating viewer bar arranges its controls (Leo 2026-11-22: "this is still bad looking").
    public static let toolbarBar = Tunable<MacScreenToolbarBar>.choice(
        "macScreen.toolbarBar", section, "Screen viewer bar",
        help: "How the screen-share viewer's floating bar arranges its controls: one row, glyphs, controls only, or the two-row bar. Applies at once.",
        default: .row, code: "MacScreenTunables.toolbarBar")

    /// Every Mac Screen tunable, for Debug Settings.
    public static var all: [TunableDescriptor] {
        [sharingLook.descriptor, devicesLook.descriptor, viewerLook.descriptor, qualityReadout.descriptor, toolbarBar.descriptor]
    }
}
