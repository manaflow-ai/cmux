import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextLayout
import os

// Strict target resolution and typed refusals for handlers. An explicit
// target that does not resolve is refused, never silently replaced by the
// focused object; a missing daemon capability disables the action with a
// reason (`ActionRegistry.bind(_:unavailable:invoke:)`).
extension AppActionContext {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    /// Logs every refusal; keyboard and menu runs also show the reason in
    /// a short HUD at the bottom of the active window (`RefusalHUD`).
    /// Control-socket runs get the reason back, and the palette shows it on
    /// the command's row (`ActionRegistry.reportingRefusal`), so neither
    /// shows the HUD.
    func observeRefusals() {
        let registry = registry
        let services = services
        registry.refusalObserver = { reason, quiet in
            Self.logger.notice("action refused: \(reason, privacy: .public)")
            guard Self.showsNotice(quiet: quiet, hasCaller: registry.refusalHasCaller) else { return }
            // Keyed by the key event that ran the refused action, so the burst bench matches it to its press.
            services.burstTrace.mark(.refusal, input: registry.dispatchingInputEvent()?.timestamp)
            services.refusalHUD.show(reason, in: services.windows.active?.window ?? NSApp.keyWindow)
        }
        // An action's local change was rolled back because the daemon refused it: say so where
        // refusals show, so the change does not just vanish.
        registry.remoteFailureObserver = { action, notice in
            Self.logger.notice("action \(action.rawValue, privacy: .public) rolled back: \(notice, privacy: .public)")
            services.refusalHUD.show(notice, in: services.windows.active?.window ?? NSApp.keyWindow)
        }
    }

    /// Reports why this invocation cannot run. Returns nil so guards can
    /// write `guard let x = lookup ?? refuse("why") else { return }`.
    @discardableResult
    func refuse<T>(_ reason: String) -> T? {
        registry.refuse(reason)
        return nil
    }

    /// Whether a refusal shows the HUD: never for a navigation no-op
    /// (R136, quiet) and never when a caller (CLI, socket, palette) shows or
    /// returns the reason itself.
    nonisolated static func showsNotice(quiet: Bool, hasCaller: Bool) -> Bool {
        !quiet && !hasCaller
    }

    /// A navigation or focus move with no target (R136): callers get the
    /// reason, a keyboard or menu run shows nothing.
    @discardableResult
    func refuseQuietly<T>(_ reason: String) -> T? {
        registry.refuse(reason, quiet: true)
        return nil
    }

    /// Statement form of ``refuseQuietly(_:)-generic``.
    func refuseQuietly(_ reason: String) {
        registry.refuse(reason, quiet: true)
    }

    /// An explicit target that names nothing (`not_found` on the socket).
    @discardableResult
    func notFound<T>(_ reason: String) -> T? {
        registry.refuseNotFound(reason)
        return nil
    }

    /// Sets `id`'s target reason (after its bind): while `reason` returns a string, the
    /// invocation's menu row is disabled and every run (palette, CLI, MCP, keyboard) is refused
    /// with it. The lookups in `reason` never refuse on their own.
    func setTargetReason(_ id: ActionID, _ reason: @escaping @MainActor (ActionInvocation) -> String?) {
        ActionTargetReasons.set(id, in: registry) { [weak registry] invocation in
            registry?.withoutRefusals { reason(invocation) }
        }
    }

    /// Runs an action's asynchronous work and reports its failure: a capturing caller (the CLI,
    /// MCP) awaits it and answers it; a palette, menu or keyboard run shows it when it comes.
    func report(_ work: @escaping @MainActor () async -> ActionWorkFailure?) {
        let task = Task { @MainActor in await work() }
        if registry.isCapturingWork {
            registry.track(task)
        } else {
            // task-owner: a run nobody awaits; the refusal shows when the work ends.
            Task { @MainActor [weak registry] in if let failure = await task.value { registry?.refuse(failure.message) } }
        }
    }

    /// Statement form: `guard ... else { return ctx.refuse("why") }`.
    func refuse(_ reason: String) {
        registry.refuse(reason)
    }

    /// Reason closure for `bind(_:unavailable:invoke:)` while the daemon
    /// lacks `capability`. It reads the daemon the action commands when
    /// availability is asked (`activeDaemon`), not the one active at bind.
    func needs(_ capability: String) -> @MainActor () -> String? {
        { [services] in
            let daemon = services.activeDaemon
            return daemon.supports(capability) ? nil : daemon.missingCapabilityMessage(capability)
        }
    }

    func connection() -> DaemonConnection? {
        services.activeDaemon.connection ?? refuse(MiscHandlerStrings.daemonOffline)
    }

    /// Runs a daemon command off the main actor; failures are logged.
    func send(_ label: String, _ body: @escaping DaemonCommandBody) {
        guard connection() != nil else { return }
        services.activeDaemon.send(label, body)
    }

    // MARK: Explicit targets

    /// Whether `invocation` names a tab or pane (target or argument).
    func namesPane(_ invocation: ActionInvocation) -> Bool {
        explicitTarget(invocation, kinds: [.tab, .pane]) != nil
    }

    private func explicitTarget(_ invocation: ActionInvocation, kinds: Set<ActionTargetKind>) -> ActionTargetRef? {
        for candidate in [invocation.target, invocation["tab"]?.targetValue, invocation["pane"]?.targetValue] {
            if let candidate, kinds.contains(candidate.kind) { return candidate }
        }
        return nil
    }

    var focusedContent: WorkspaceContentController? { services.windows.active?.content }

    /// The pane controller for the targeted tab or pane, else the focused
    /// pane. Refuses an unknown target or one not shown in any window.
    func paneController(_ invocation: ActionInvocation) -> PaneController? {
        guard let target = explicitTarget(invocation, kinds: [.tab, .pane]) else {
            return services.windows.active?.focusedPane ?? refuse(MiscHandlerStrings.noPane)
        }
        for window in services.windows.controllers {
            for pane in window.content?.panes.values.map({ $0 }) ?? [] {
                let hit = target.kind == .pane
                    ? pane.paneKey == target.id
                    : pane.stripModel.tab(StripTabID(target.id)) != nil
                if hit { return pane }
            }
        }
        return refuse(RefusalStrings.notShownInAnyWindow(String(describing: target)))
    }

    /// The targeted tab (with its controller), else the focused pane's selected tab.
    func tab(_ invocation: ActionInvocation) -> (pane: PaneController, id: StripTabID)? {
        guard let pane = paneController(invocation) else { return nil }
        if let target = explicitTarget(invocation, kinds: [.tab]) { return (pane, StripTabID(target.id)) }
        guard let id = pane.stripModel.selectedID else { return refuseQuietly(RefusalStrings.focusedPaneHasNoTab) }
        return (pane, id)
    }

    /// The tabs a tab action on `id` acts on: every selected tab of `pane`'s strip from a menu opened
    /// on one of them (`actsOnTabSelection`) or from the palette or a shortcut on the focused tab (no
    /// tab target), else `id`. So the tab menu and Cmd-Shift-P act on the same tabs.
    func actingTabs(_ invocation: ActionInvocation, _ pane: PaneController, _ id: StripTabID) -> [StripTabID] {
        invocation.actsOnTabSelection || explicitTarget(invocation, kinds: [.tab]) == nil ? pane.stripModel.actingTabs(for: id) : [id]
    }

    /// The daemon tabs Move Tab to New Workspace or Window takes for `tab`: on one of several
    /// selected tabs, every selected tab that may move, in strip order (`tab` among them); else `tab`.
    func movingTabs(_ invocation: ActionInvocation, _ tab: TabModel) -> [TabModel] {
        guard let pane = services.locateTab(tab.id).flatMap({ services.paneController(for: $0.1) }) else { return [tab] }
        return actingTabs(invocation, pane, StripTabID(tab.id)).compactMap { pane.tab($0) }.filter { $0.id == tab.id || TabPromotion.refusal(tab: $0.id, services: services) == nil }
    }

    /// The targeted daemon tab, found in any workspace (shown or not).
    func daemonTab(_ invocation: ActionInvocation) -> (tab: TabModel, pane: PaneModel)? {
        if let target = explicitTarget(invocation, kinds: [.tab]) {
            return services.locateTab(target.id) ?? notFound(RefusalStrings.noTab(target.id))
        }
        guard let (pane, id) = tab(invocation) else { return nil }
        guard let tab = pane.tab(id) else { return refuseQuietly(RefusalStrings.noTab(id.rawValue)) }
        return (tab, pane.pane)
    }

    /// The targeted daemon pane, found in any workspace.
    func daemonPane(_ invocation: ActionInvocation) -> PaneModel? {
        if let target = explicitTarget(invocation, kinds: [.pane]) {
            let panes = services.activeDaemon.store.workspaces.flatMap(\.screens).flatMap(\.panes)
            return panes.first { $0.id == target.id } ?? notFound(RefusalStrings.noPaneID(target.id))
        }
        if explicitTarget(invocation, kinds: [.tab]) != nil { return daemonTab(invocation)?.pane }
        return paneController(invocation)?.pane
    }

    /// The daemon workspace named by a `workspace` argument.
    func workspaceArgument(_ invocation: ActionInvocation) -> WorkspaceModel? {
        guard let ref = invocation["workspace"]?.targetValue else { return refuse(RefusalStrings.workspaceArgumentRequired) }
        return services.workspace(id: ref.id) ?? notFound(RefusalStrings.noWorkspace(ref.id))
    }

    /// The focused window's workspace content, required for layout actions.
    func content(_ invocation: ActionInvocation = ActionInvocation()) -> WorkspaceContentController? {
        if explicitTarget(invocation, kinds: [.tab, .pane]) != nil {
            guard let pane = paneController(invocation) else { return nil }
            return pane.workspace ?? refuse(RefusalStrings.paneHasNoWorkspaceView(pane.paneKey))
        }
        return focusedContent ?? refuse(RefusalStrings.noWindowShowsWorkspace)
    }

    /// Selects `pane`'s tab first when the invocation targets a hidden one,
    /// so content-level actions (terminal, browser) act on it.
    func visibleContent(_ invocation: ActionInvocation) -> (pane: PaneController, content: TabContent)? {
        guard let (pane, id) = tab(invocation) else { return nil }
        if pane.stripModel.selectedID != id {
            guard pane.stripModel.tab(id) != nil else { return refuse(RefusalStrings.noTab(id.rawValue)) }
            pane.select(id)
        }
        // Content destroyed while its pane was off screen re-attaches now.
        if pane.currentContent == nil { pane.showSelected() }
        guard let content = pane.currentContent else { return refuse(RefusalStrings.tabHasNoLiveContent(id.rawValue)) }
        return (pane, content)
    }

    /// The live terminal surface of the targeted or focused tab.
    func terminal(_ invocation: ActionInvocation) -> TerminalEntry? {
        guard let (_, content) = visibleContent(invocation) else { return nil }
        guard case .terminal(let entry) = content else { return refuse(RefusalStrings.notATerminal) }
        return entry
    }
}
