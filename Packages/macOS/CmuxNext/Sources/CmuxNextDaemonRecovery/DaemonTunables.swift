public import CmuxNextDesign

/// Debug Settings of the local cmux-tui's automatic restart (plans/cmux-next/server-updates-DESIGN.md):
/// on by default; the toggle lets DEV and NIGHTLY turn it off. Release and RC never activate the
/// store, so they keep the default. The restart keeps every terminal.
public nonisolated struct DaemonTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "cmuxTUI", title: "cmux-tui", symbol: "terminal", order: 42)

    /// A cmux-tui that stays alive but never answers restarts after a sustained window
    /// (`UnresponsiveOwnerWatch`). Off: only Restart cmux-tui in the disconnected window restarts it.
    public static let restartUnresponsiveCmuxTUI = Tunable<Bool>.toggle(
        "cmuxTUI.restartUnresponsive", section, "Restart an unresponsive cmux-tui",
        help: "A cmux-tui that stops answering for 30 seconds restarts by itself. Terminals keep running.",
        default: true, code: "DaemonTunables.restartUnresponsiveCmuxTUI")

    public static var all: [TunableDescriptor] {
        [restartUnresponsiveCmuxTUI.descriptor]
    }
}
