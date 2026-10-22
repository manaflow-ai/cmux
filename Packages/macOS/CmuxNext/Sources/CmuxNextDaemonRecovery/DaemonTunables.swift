public import CmuxNextDesign

/// Debug Settings of the local cmux-tui's automatic restarts (plans/cmux-next/server-updates-DESIGN.md
/// rule 2): on by default; the toggles let DEV and NIGHTLY turn one off. Release and RC never
/// activate the store, so they keep the defaults. Both restarts keep every terminal.
public nonisolated struct DaemonTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "cmuxTUI", title: "cmux-tui", symbol: "terminal", order: 42)

    /// A cmux-tui of another build than the bundled one (or one that lacks capabilities this app
    /// uses) is updated automatically (`QuietDaemonUpdate`): at a quiet moment, or once two
    /// minutes passed at the first moment no app request is in flight. Off: only the update
    /// toast's Restart cmux-tui… restarts it.
    public static let restartStaleCmuxTUIWhenQuiet = Tunable<Bool>.toggle(
        "cmuxTUI.restartStaleWhenQuiet", section, "Update a stale cmux-tui automatically",
        help: "A cmux-tui of an older build restarts by itself at a quiet moment, or within about two minutes even while a chat or TUI is attached. Terminals keep running.",
        default: true, code: "DaemonTunables.restartStaleCmuxTUIWhenQuiet")

    /// A cmux-tui that stays alive but never answers restarts after a sustained window
    /// (`UnresponsiveOwnerWatch`). Off: only Restart cmux-tui in the disconnected window restarts it.
    public static let restartUnresponsiveCmuxTUI = Tunable<Bool>.toggle(
        "cmuxTUI.restartUnresponsive", section, "Restart an unresponsive cmux-tui",
        help: "A cmux-tui that stops answering for 30 seconds restarts by itself. Terminals keep running.",
        default: true, code: "DaemonTunables.restartUnresponsiveCmuxTUI")

    public static var all: [TunableDescriptor] {
        [restartStaleCmuxTUIWhenQuiet.descriptor, restartUnresponsiveCmuxTUI.descriptor]
    }
}
