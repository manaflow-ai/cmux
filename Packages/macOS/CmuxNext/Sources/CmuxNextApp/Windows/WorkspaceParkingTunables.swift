import CmuxNextDesign

/// Debug Settings of how a window parks the workspaces it does not show (DEV and NIGHTLY). English
/// developer text, as every Debug Settings section.
enum WorkspaceParkingTunables {
    /// Off (the default): a parked workspace is hidden. On: it stays unhidden at alpha 0 and parked
    /// (`ParkingContainer`), so a switch back sends WindowServer no new layer tree (offender 4 of the
    /// 2026-10-21 GPU audit: hiding costs about 30 ms of WindowServer per pane on each switch back).
    /// Stays off until Chromium pages conceal on the parked signal: until then a workspace with a page
    /// on screen is still hidden, and a page that appears hides every workspace parked this way
    /// (`WindowRootView.hideAlphaParkedWorkspaces`).
    static let parkByAlpha = Tunable<Bool>.toggle(
        "workspace.parkByAlpha", .panes, "Park workspaces by alpha",
        help: "A workspace you switch away from stays in the window at alpha 0 instead of hidden, so switching back costs WindowServer far less. Workspaces with a Chromium page stay hidden; WebKit pages in a parked workspace keep running. Applies to the next switch.",
        default: false, code: "WorkspaceParkingTunables.parkByAlpha")

    static var all: [TunableDescriptor] { [parkByAlpha.descriptor] }
}
