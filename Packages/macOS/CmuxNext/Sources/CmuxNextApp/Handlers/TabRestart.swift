import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTerminal

/// `tab.restart` (plans/cmux-next/ownership.md 3.2): restart a dead terminal
/// tab in place with a new shell in its last directory. The dead-tab
/// overlay's button, the tab's right-click item, the palette and
/// `cmux tab restart` all run this one action; it sends `restart-tab` and
/// the store shows the result from the daemon's echo (no local patch).
enum TabRestart {
    static let action: ActionID = "tab.restart"

    /// `RestartTabRequest.idempotencyKey`: the same key for a manual
    /// restart, the automatic one and other clients.
    static func idempotencyKey(_ tab: TabModel) -> String { RestartTabRequest.idempotencyKey(tab: tab.snapshot) }

    /// A local daemon terminal tab whose terminal ended.
    static func isRestartable(_ tab: TabModel) -> Bool {
        tab.kind == .pty && tab.dead && tab.remote == nil
    }

    /// The dead-tab overlay's buttons run `tab.restart` and `closeTab` on
    /// this tab; a daemon without `tab-restart-v1` gets only Close.
    static func offer(on entry: TerminalEntry, tab: TabModel, daemon: DaemonService, registry: ActionRegistry) {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
        var actions = TerminalDeadTabActions()
        actions.close = { [weak registry] in _ = registry?.perform("closeTab", invocation: invocation) }
        if daemon.supports(DaemonCapabilities.shared.tabRestart) {
            actions.restart = { [weak registry] in _ = registry?.perform(action, invocation: invocation) }
        }
        entry.session.view.deadTabActions = actions
    }

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(action, unavailable: ctx.needs(DaemonCapabilities.shared.tabRestart), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard isRestartable(tab) else { return ctx.refuse(RefusalStrings.tabNotDead) }
            let surface = tab.surface, cwd = tab.cwd
            let key = idempotencyKey(tab)
            let daemon = ctx.services.activeDaemon
            ctx.registry.track(Task {
                let ok = await daemon.run("restart-tab") { connection in
                    try await connection.restartTab(surface, idempotencyKey: key, fallbackCwd: cwd)
                }
                return ok ? nil : "restart-tab failed (see the app log)"
            })
        })
    }
}
