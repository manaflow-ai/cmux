import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTerminal

/// `tab.restart` (plans/cmux-next/ownership.md 3.2, cx-7e7b): a terminal
/// tab whose shell ended gets a new shell under the same terminal id
/// (`restart-tab`). The dead-tab overlay's button, the tab's right-click
/// item, the palette and `cmux tab <id> restart` all run this one action
/// (the CLI sends the same daemon command). The store shows the result from
/// the daemon's tree push: the tab turns live and its view re-attaches.
enum TabRestart {
    static let action: ActionID = "tab.restart"

    /// A daemon terminal tab whose shell ended.
    static func isRestartable(_ tab: TabModel) -> Bool {
        tab.kind == .pty && tab.dead
    }

    /// The dead-tab overlay's button runs `tab.restart` on this tab; a
    /// daemon without `tab-restart-v1` gets no button.
    @MainActor
    static func offer(on entry: TerminalEntry, tab: TabModel, daemon: DaemonService, registry: ActionRegistry) {
        guard daemon.supports(DaemonCapabilities.shared.tabRestart) else {
            entry.session.view.onRestart = nil
            return
        }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
        entry.session.view.onRestart = { [weak registry] in _ = registry?.perform(action, invocation: invocation) }
    }

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(action, unavailable: ctx.needs(DaemonCapabilities.shared.tabRestart), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            guard tab.dead else { return ctx.refuse(RefusalStrings.tabNotDead) }
            let surface = tab.surface
            ctx.send("restart-tab") { _ = try await $0.request(RestartTabRequest(surface: surface)) }
        })
    }
}
