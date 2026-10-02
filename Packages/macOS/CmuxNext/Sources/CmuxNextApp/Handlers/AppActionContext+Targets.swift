import AppKit
import CmuxNextActions
import CmuxNextBridge
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
        registry.refusalObserver = { reason in
            Self.logger.notice("action refused: \(reason, privacy: .public)")
            guard !registry.refusalHasCaller else { return }
            services.refusalHUD.show(reason, in: services.windows.active?.window ?? NSApp.keyWindow)
        }
    }

    /// Reports why this invocation cannot run. Returns nil so guards can
    /// write `guard let x = lookup ?? refuse("why") else { return }`.
    @discardableResult
    func refuse<T>(_ reason: String) -> T? {
        registry.refuse(reason)
        return nil
    }

    /// An explicit target that names nothing (`not_found` on the socket).
    @discardableResult
    func notFound<T>(_ reason: String) -> T? {
        registry.refuseNotFound(reason)
        return nil
    }

    /// Statement form: `guard ... else { return ctx.refuse("why") }`.
    func refuse(_ reason: String) {
        registry.refuse(reason)
    }

    /// Reason closure for `bind(_:unavailable:invoke:)` while the daemon
    /// lacks `capability`.
    func needs(_ capability: String) -> @MainActor () -> String? {
        let daemon = services.activeDaemon
        return { daemon.supports(capability) ? nil : daemon.missingCapabilityMessage(capability) }
    }

    func connection() -> DaemonConnection? {
        services.activeDaemon.connection ?? refuse(MiscHandlerStrings.daemonOffline)
    }

    /// Runs a daemon command off the main actor; failures are logged.
    func send(_ label: String, _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        guard connection() != nil else { return }
        services.activeDaemon.send(label, body)
    }

    // MARK: Explicit targets

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
        guard let id = pane.stripModel.selectedID else { return refuse(RefusalStrings.focusedPaneHasNoTab) }
        return (pane, id)
    }

    /// The targeted daemon tab, found in any workspace (shown or not).
    func daemonTab(_ invocation: ActionInvocation) -> (tab: TabModel, pane: PaneModel)? {
        if let target = explicitTarget(invocation, kinds: [.tab]) {
            return services.locateTab(target.id) ?? notFound(RefusalStrings.noTab(target.id))
        }
        guard let (pane, id) = tab(invocation) else { return nil }
        guard let tab = pane.tab(id) else { return refuse(RefusalStrings.sessionLocalTab(id.rawValue)) }
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
