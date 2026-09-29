import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// New terminal tab, new browser tab, and close tab for a shown pane (the
/// strip's optimistic path) or any daemon pane, so the CLI can act on a
/// workspace no window shows. Every daemon command is tracked
/// (`ActionRegistry.track`) for callers that await the effect.
enum TabLifecycle {
    static func newTerminal(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let pane = ctx.daemonPane(invocation) else { return }
        let cwd = invocation["cwd"]?.stringValue
        if let controller = ctx.services.paneController(for: pane) { return controller.newTerminalTab(cwd: cwd) }
        let handle = pane.handle
        let start = cwd ?? pane.tabs.first?.cwd
        ctx.send("new-tab") { _ = try await $0.newTab(in: handle, options: SpawnOptions(cwd: start)) }
    }

    static func newBrowser(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        var url: URL?
        if let text = invocation["url"]?.stringValue {
            guard let resolved = BrowserURLResolver().url(for: text) else { return ctx.refuse(MiscHandlerStrings.invalidURL(text)) }
            url = resolved
        }
        guard let pane = ctx.daemonPane(invocation) else { return }
        let engine = invocation["engine"]?.stringValue
        if let controller = ctx.services.paneController(for: pane) { return controller.newBrowserTab(url: url, engine: engine) }
        let browserTabs = ctx.services.cache.browserTabs!
        guard browserTabs.isAvailable() else { return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.frontendBrowserTabs)) }
        let handle = pane.handle, tag = browserTabs.engine(requested: engine), address = url?.absoluteString ?? "about:blank"
        let logger = ctx.services.daemon.logger
        ctx.registry.track(Task {
            do {
                _ = try await browserTabs.create(handle, address, tag)
                return nil
            } catch {
                logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// With an explicit tab target the tab may be in any workspace; without
    /// one, the focused pane's selected tab (session-local browser tabs too).
    static func close(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil else {
            guard let (pane, id) = ctx.tab(invocation) else { return }
            return pane.close([id])
        }
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return }
        if let controller = ctx.services.paneController(for: pane) { return controller.close([StripTabID(tab.id)]) }
        if tab.kind == .pty, let terminal = tab.terminalID {
            let incarnation = tab.terminalIncarnation
            ctx.send("close-terminal") { try await $0.closeTerminal(terminal, incarnation: incarnation) }
        } else {
            let surface = tab.surface
            ctx.send("close-surface") { try await $0.closeTab(surface) }
        }
    }

    /// The explicitly targeted tab when no window shows it (rename and pin
    /// then go straight to the daemon; shown tabs use the strip's path).
    private static func hiddenTab(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> TabModel? {
        guard invocation.target?.kind == .tab || invocation["tab"]?.targetValue != nil,
              let (tab, pane) = ctx.daemonTab(invocation), ctx.services.paneController(for: pane) == nil else { return nil }
        return tab
    }

    /// Renames a hidden targeted tab. Returns false when the tab is shown
    /// (or not targeted) and the caller should take the strip path.
    static func renameHidden(_ ctx: AppActionContext, _ invocation: ActionInvocation, name: String?) -> Bool {
        guard let tab = hiddenTab(ctx, invocation), let name else { return false }
        let surface = tab.surface
        ctx.send("rename-surface") { try await $0.renameTab(surface, to: name) }
        return true
    }

    static func togglePinHidden(_ ctx: AppActionContext, _ invocation: ActionInvocation) -> Bool {
        guard let tab = hiddenTab(ctx, invocation) else { return false }
        let surface = tab.surface, pinned = !tab.pinned
        ctx.send("set-tab-pinned") { _ = try await $0.setTabPinned(surface, pinned) }
        return true
    }
}
