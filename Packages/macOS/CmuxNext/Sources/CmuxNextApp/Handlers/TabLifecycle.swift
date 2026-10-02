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
        // `--keep`: the terminal outlives its tab (a background terminal made on purpose).
        let keep = invocation["keep"]?.boolValue == true ? true : nil
        if let controller = ctx.services.paneController(for: pane) { return controller.newTerminalTab(cwd: cwd, keep: keep, fromSelectedTab: true) }
        let handle = pane.handle
        let start = cwd ?? pane.tabs.first?.cwd
        let workspace = ctx.services.workspaceKey(of: pane)
        ctx.send("new-tab") { _ = try await $0.newTab(in: handle, options: SpawnOptions(cwd: start, workspace: workspace, keep: keep)) }
    }

    /// `newTab.sameKind` (Cmd-T): a tab of the kind of the pane's selected
    /// tab (`NewTabKind`), through the New Terminal Tab and New Browser Tab
    /// paths, so focus and options match them.
    static func newTabOfPaneKind(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        guard let pane = ctx.daemonPane(invocation) else { return }
        // The targeted tab (CLI `--tab`), else the pane's selected tab (an
        // empty pane has none and gets a terminal; never a refusal).
        let selectedID = invocation.target?.kind == .tab ? invocation.target?.id
            : ctx.services.paneController(for: pane)?.stripModel.selectedID?.rawValue
            ?? (pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex].id : nil)
        let tab = pane.tabs.first { $0.id == selectedID }
        let local = selectedID?.hasPrefix(LocalBrowserTab.prefix) == true
        switch NewTabKind.resolve(selectedKind: tab?.kind, engine: tab?.browserEngine, isLocalBrowser: local) {
        case .terminal:
            newTerminal(ctx, invocation)
        case .browser(let engine):
            var invocation = invocation
            invocation.arguments["cwd"] = nil
            if let engine { invocation.arguments["engine"] = .string(engine) }
            newBrowser(ctx, invocation)
        }
    }

    /// `openBrowser.webkit` and `openBrowser.chromium`: `openBrowser` with a fixed engine.
    static func newBrowser(_ ctx: AppActionContext, _ invocation: ActionInvocation, engine: BrowserEngineTag) {
        var invocation = invocation
        invocation.arguments["engine"] = .string(engine.rawValue)
        newBrowser(ctx, invocation)
    }

    /// Reopens a browser tab's page on the other engine in the same pane,
    /// then closes the original (engines are fixed per tab).
    static func reopen(_ ctx: AppActionContext, _ invocation: ActionInvocation, on engine: BrowserEngineTag) {
        guard let (pane, id) = ctx.tab(invocation) else { return }
        guard let tab = pane.tab(id), tab.kind == .browser else { return ctx.refuse(RefusalStrings.notABrowserTab) }
        let current = BrowserEngineTag(rawValue: tab.browserEngine ?? "") ?? .webkit
        guard current != engine else { return }
        if engine == .cef, let reason = ctx.services.cache.browserTabs?.cefUnavailableReason() {
            return ctx.refuse(reason)
        }
        let live = ctx.services.cache.existingBrowser(tab.id)?.tab.state.url
        let url = live ?? tab.url.flatMap(URL.init(string:))
        pane.newBrowserTab(url: url, engine: engine.rawValue)
        pane.close([id])
    }

    /// `openBrowser` (`engine` optional: `browser.defaultEngine` when
    /// absent, see `BrowserEngineResolver`). An explicit Chromium request
    /// never silently becomes WebKit.
    static func newBrowser(_ ctx: AppActionContext, _ invocation: ActionInvocation) {
        var url: URL?
        if let text = invocation["url"]?.stringValue {
            let chromium = invocation["engine"]?.stringValue == BrowserEngineTag.cef.rawValue
            guard let resolved = BrowserURLResolver(allowsChromiumSchemes: chromium).url(for: text) else {
                return ctx.refuse(MiscHandlerStrings.invalidURL(text))
            }
            url = resolved
        }
        guard let pane = ctx.daemonPane(invocation) else { return }
        let engine = invocation["engine"]?.stringValue
        // A tab the CLI, MCP or a script opens is an agent's: no saved password fills in it (plans/cmux-next/browser.md).
        let cache: TabContentCache? = ctx.services.cache
        var agentTab: (@MainActor (SurfaceID) -> Void)?
        if [.cli, .mcp, .script].contains(invocation.origin) {
            agentTab = { @MainActor [weak cache] surface in cache?.markAgentDriven(surface: surface) }
        }
        if let controller = ctx.services.paneController(for: pane) {
            // No URL given: what the selected tab works on (#16620).
            return url == nil ? controller.newBrowserTabFromSelectedTab(engine: engine, then: agentTab)
                : controller.newBrowserTab(url: url, engine: engine, then: agentTab)
        }
        let browserTabs = ctx.services.cache.browserTabs!
        guard browserTabs.isAvailable() else { return ctx.refuse(RefusalStrings.needsDaemonCapability(DaemonCapabilities.shared.frontendBrowserTabs)) }
        let choice: BrowserEngineChoice
        switch browserTabs.resolve(requested: engine) {
        case .refuse(let reason): return ctx.refuse(BrowserTabService.message(reason))
        case .open(let resolved): choice = resolved
        }
        let handle = pane.handle, address = url?.absoluteString ?? ctx.services.newTabAddress(for: choice)
        let logger = ctx.services.daemon.logger
        ctx.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: handle, url: address)
                agentTab?(surface)
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
        let command = ctx.services.daemon(for: pane).closeCommand(for: tab)
        if tab.kind == .remoteTerminal { ctx.services.remoteTerminals.viewClosed(tab) }
        ctx.send(command.label, command.run)
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
