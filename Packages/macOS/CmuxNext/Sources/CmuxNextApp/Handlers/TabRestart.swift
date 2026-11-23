import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTerminal
import CmuxNextWindowRules

/// `tab.restart` (ownership.md 3.2, cx-7e7b): an ended shell restarts under its terminal id (`restart-tab`);
/// a failed host link is Recover (the daemon rehosts the same running shell). The overlay button, tab menu,
/// palette and `cmux tab <id> restart` run this one action; the tree push shows the tab live again.
enum TabRestart {
    static let action: ActionID = "tab.restart"

    /// Why `tab` cannot restart (Rust's `tabs::restart_refusal`: a daemon terminal tab whose shell ended,
    /// or whose host link failed, can), nil when it can; `answered` false when the FFI does not answer.
    static func refusal(_ tab: TabModel) -> (refusal: String?, answered: Bool) {
        WindowRules().restartRefusal(pty: tab.kind == .pty, dead: tab.dead, failed: tab.terminalState == .failed)
    }

    static func isRestartable(_ tab: TabModel) -> Bool { refusal(tab) == (nil, true) }

    /// The tab menu's rows to hide: Restart unless the tab can restart.
    static func hiddenMenuItems(_ tab: TabModel?) -> Set<ActionID> {
        (tab.map(isRestartable) ?? false) ? [] : [action]
    }

    /// The dead-tab overlay's button runs `tab.restart` on this tab; a
    /// daemon without `tab-restart-v1` gets no button.
    @MainActor
    static func offer(on entry: TerminalEntry, tab: TabModel, daemon: DaemonService, registry: ActionRegistry) {
        guard daemon.supports(DaemonCapability.tabRestart.rawValue) else {
            entry.session.view.onRestart = nil
            return
        }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
        entry.session.view.onRestart = { [weak registry] in _ = registry?.perform(action, invocation: invocation) }
    }

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(action, unavailable: ctx.needs(DaemonCapability.tabRestart.rawValue), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            switch refusal(tab) {
            case (nil, true): break
            case ("notATerminal"?, _): return ctx.refuse(RefusalStrings.notATerminal)
            default: return ctx.refuse(RefusalStrings.tabNotDead)
            }
            let surface = tab.surface
            ctx.send("restart-tab") { _ = try await $0.request(RestartTabRequest(surface: surface)) }
        })
    }
}

/// A daemon terminal tab's content: the cached surface (attached on demand
/// over the pane's daemon), its theme, and the dead-tab overlay's Restart.
@MainActor
enum TerminalTabContent {
    static func make(_ tab: TabModel, in pane: PaneController) -> TabContent? { // nil: a stand-in's surface waits for its key's frame
        let services = pane.services, daemon = pane.daemon
        // A stand-in's surface follows its key's frame, then this pane shows it again while it still shows it (one surface per frame).
        guard !ProvisionalTab.isProvisional(surface: tab.surface) || !services.cache.standInTerminals.waits(tab.id, standIn: true, exists: services.cache.existingTerminal(tab.id) != nil,
                                                                                                            showAgain: { [weak pane] in pane?.showsAgain(tab.id) ?? false }) else { return nil }
        let entry = BenchSpans.measure("terminal.surface") { services.cache.terminal(for: tab, daemon: daemon) }
        services.themes.catchUp(entry, fresh: true)
        TabRestart.offer(on: entry, tab: tab, daemon: daemon, registry: services.registry)
        // A pane that still starts offers Close in its label: Close Tab on this tab, the one path of
        // its shortcut on the focused pane and of the tab's close button (the tab keeps its id at the confirm).
        let close = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), origin: .user)
        entry.session.view.onCloseStarting = { [weak registry = services.registry] in _ = registry?.perform("closeTab", invocation: close) }
        return .terminal(entry)
    }
}
