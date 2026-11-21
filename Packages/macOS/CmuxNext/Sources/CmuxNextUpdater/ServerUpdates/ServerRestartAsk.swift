public import CmuxNextDesign
public import CmuxUpdater

/// How a server restart asks: at most once. When a person started it (the toast's Restart, the
/// palette's Restart cmux-tui… in this app) and nothing would be lost (no agent mid-turn, no
/// foreground command running, the daemon's mirror confirmed, and a restart that keeps running
/// work), it restarts at once: the click was the ask. Otherwise it shows the one confirm
/// (``ServerUpdateNotice/confirmSpec``) and restarts only on its Restart. A run an agent, script,
/// page or the control socket started always shows it: only a person's click is the ask (design
/// audit 2026-11-18 #20; Leo: "All 4 do em these didn't need my addl input").
public struct ServerRestartAsk {
    public init() {}
    /// The confirm to show before restarting, or nil when the person's click is enough.
    public static func prompt(for notice: ServerUpdateNotice, blockers: UpdateRelaunchBlockers, byPerson: Bool) -> CmuxDialogSpec? {
        byPerson && losesNothing(notice, blockers: blockers) ? nil : notice.confirmSpec
    }

    /// Whether a restart now loses nothing: it keeps running work, and nothing is mid-way.
    /// An unconfirmed daemon mirror counts as something to lose (it cannot be proved empty);
    /// recent typing does not (the click itself is input).
    public static func losesNothing(_ notice: ServerUpdateNotice, blockers: UpdateRelaunchBlockers) -> Bool {
        !notice.impact.isDestructive && !blockers.daemonStateUnavailable && blockers.forUserInstall.isEmpty
    }

    /// Runs one restart request: `ask` shows the prompt and answers whether the person chose
    /// Restart; `restart` runs on that answer, or at once when there is no prompt; `declined` runs
    /// when they did not.
    public static func run(_ notice: ServerUpdateNotice, blockers: UpdateRelaunchBlockers, byPerson: Bool,
                           ask: (CmuxDialogSpec, @escaping @MainActor (Bool) -> Void) -> Void,
                           restart: @escaping @MainActor () -> Void, declined: @escaping @MainActor () -> Void) {
        guard let spec = prompt(for: notice, blockers: blockers, byPerson: byPerson) else { return restart() }
        ask(spec) { $0 ? restart() : declined() }
    }
}
