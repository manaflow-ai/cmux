import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextBrowserHost
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Observation

/// The app's browser tabs for the browser host: the tab list (`hello`,
/// `tab.announced`/`navigated`/`gone`), each Chromium tab's extension access
/// (`tab.access`), the WebKit driver's tab provider, and the agent mark.
///
/// Only the local daemon's workspaces, and no incognito tab: agents on this
/// machine drive tabs this machine's store owns. The getters read the store
/// and the live pages, which are observable, plus `pageInstalls` (a page was
/// created); visibility is pushed with `refreshTabs()`.
final class AppBrowserHostTabs: ProviderTabSource, ProviderAccessSource, AutomationTabProvider, ProviderAgentMarking, ProviderTabOpening {
    private weak var services: AppServices?
    /// Extension access depends on manifests read from disk: computed again
    /// only when the profile's extension list or the page URL changes.
    private var accessMemo: [String: (extensions: [BrowserExtensionInfo], url: URL?, names: [String])] = [:]
    /// Hidden agent-driven WebKit tabs render here (``keepRendering(_:)``).
    let renderWindows = AgentRenderWindows()

    init(services: AppServices) {
        self.services = services
    }

    private struct LocalTab {
        let model: TabModel
        let workspace: WorkspaceModel
    }

    private var localBrowserTabs: [LocalTab] {
        guard let services else { return [] }
        let cache: TabContentCache = services.cache
        var out: [LocalTab] = []
        for workspace in services.daemon.store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.kind == .browser && cache.browserTabs.isIncognitoTab(tab.id) == false {
                        out.append(LocalTab(model: tab, workspace: workspace))
                    }
                }
            }
        }
        return out
    }

    /// A tab the app announces: a browser tab of a local workspace, not incognito.
    func isDrivable(_ targetID: String) -> Bool {
        localBrowserTabs.contains { $0.model.id == targetID }
    }

    /// The workspace that holds an announced tab (agent input routing).
    func workspaceID(ofTab targetID: String) -> String? {
        localBrowserTabs.first { $0.model.id == targetID }?.workspace.id
    }

    // MARK: ProviderTabSource

    var providerTabs: [ProviderTab] {
        guard let services else { return [] }
        let cache: TabContentCache = services.cache
        _ = cache.pageInstalls.revision
        return localBrowserTabs.map { entry in
            let tab = entry.model
            let page = cache.existingBrowser(tab.id)?.tab
            return ProviderTab(
                targetID: tab.id, engine: Self.engine(of: tab, page: page), workspace: entry.workspace.id,
                profile: (page?.profileID ?? cache.browserProfile?(tab.id) ?? .default).rawValue.uuidString,
                url: page?.state.url?.absoluteString ?? tab.url ?? "about:blank",
                title: page?.state.title ?? tab.title, visible: cache.isRendering(tab.id))
        }
    }

    /// The engine that renders the tab now: a Chromium record shown in
    /// WebKit (CEF missing) is a WebKit tab for the host.
    private static func engine(of tab: TabModel, page: (any BrowserTab)?) -> ProviderEngine {
        if page is WebKitTab { return .webkit }
        if page is CEFTab { return .cef }
        return tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
    }

    // MARK: ProviderAccessSource

    /// The interim extension rule (plans/cmux-next/passwords.md, section 3.4),
    /// the same formula as `AppBrowserPage.agentExtensionRefusal`.
    func access(forTab targetID: String) -> ProviderTabAccess {
        guard let services else { return ProviderTabAccess(extensionHostAccess: false, userOverride: false, extensions: []) }
        let cache: TabContentCache = services.cache
        let override = cache.agentMayUseExtensionTab(targetID)
        let page = cache.existingBrowser(targetID)?.tab
        let profile = page?.profileID ?? cache.browserProfile?(targetID) ?? .default
        guard let store = (page as? any BrowserExtensionActionHosting)?.extensionStore ?? cache.cef.extensionStore(for: profile) else {
            accessMemo[targetID] = nil
            return ProviderTabAccess(extensionHostAccess: false, userOverride: override, extensions: [])
        }
        let url = page?.state.url ?? cache.tabModel(targetID)?.url.flatMap(URL.init(string:))
        let extensions = store.extensions
        let names: [String]
        if let memo = accessMemo[targetID], memo.extensions == extensions, memo.url == url {
            names = memo.names
        } else {
            names = AgentExtensionAccess.fromDisk.blockers(extensions, url: url).map(\.name)
            accessMemo[targetID] = (extensions, url, names)
        }
        return ProviderTabAccess(extensionHostAccess: !names.isEmpty, userOverride: override, extensions: names)
    }

    // MARK: ProviderAgentMarking

    /// Saved passwords never fill in a tab an agent drives, or in its popups.
    /// A live Chromium page that was not agent-driven may already hold a
    /// filled password, so it is rebuilt before any agent message reaches it
    /// (the relay waits for the new page).
    func agentWillDrive(targetID: String) {
        guard let services, isDrivable(targetID) else { return }
        if AppBrowserPage.markAgentDriven(targetID, services: services) {
            services.cache.rebuildForAgent(targetID)
        }
    }

    // MARK: AutomationTabProvider (WebKit driver)

    func automationTabs(all: Bool) -> [AutomationTab] {
        guard let services else { return [] }
        let cache: TabContentCache = services.cache
        return localBrowserTabs.compactMap { entry in
            guard let page = cache.existingBrowser(entry.model.id)?.tab as? WebKitTab else { return nil }
            return AutomationTab(tab: page, windowID: entry.workspace.id, isActive: cache.isRendering(entry.model.id))
        }
    }

    /// `tabs.open` from a WebKit session (browser-host.md, D12: the app
    /// picks the place, never the agent): a WebKit store tab in the
    /// background (``openSessionTab(_:url:)``), then its page. The session
    /// owns the tab: its end closes it (``endSessionTab(_:)``) unless it was
    /// kept. The driver navigates it.
    func openAutomationTab(url: URL?) async throws -> WebKitTab {
        guard let services else { throw AutomationTabError.unavailable }
        let tab = try await openSessionTab(.webkit, url: nil)
        guard let page = services.cache.browser(for: tab)?.tab as? WebKitTab else {
            throw AutomationTabError.unavailable
        }
        return page
    }

    // MARK: ProviderTabOpening (Chromium sessions)

    /// `tabs.open` from a Chromium session: a Chromium store tab in the
    /// background. Its page starts when the host first attaches to it (the
    /// relay's prepare creates it hidden). An explicit Chromium request never
    /// becomes a WebKit tab: without Chromium it is refused.
    func openProviderTab(engine: ProviderEngine, url: String?) async throws(DriverError) -> String {
        guard engine == .cef else {
            throw DriverError(.unsupported, "tabs.open: WebKit tabs open through the WebKit driver")
        }
        do {
            return try await openSessionTab(.cef, url: url).id
        } catch {
            throw DriverError(.unsupported, "tabs.open: \(error.localizedDescription)")
        }
    }

    /// A store tab of `engine` for a browser session, in the background (the
    /// pane's active tab stays: every client reads it; no selection or focus
    /// changes), in ``sessionTabPane(_:)``. Answers once the store shows it.
    private func openSessionTab(_ engine: BrowserEngineTag, url: String?) async throws -> TabModel {
        guard let services, let browserTabs = services.cache.browserTabs, browserTabs.isAvailable() else {
            throw AutomationTabError.unavailable
        }
        if engine == .cef, let reason = browserTabs.cefUnavailable() {
            throw AutomationTabError.chromiumUnavailable(BrowserTabService.message(reason))
        }
        let pane = try sessionTabPane(browserTabs)
        let surface = try await browserTabs.open(BrowserEngineChoice(engine: engine), in: pane,
                                                 url: url ?? "about:blank", activate: false)
        // The create reply can come before the store shows the tab.
        let appeared = try? await ControlDeadline.shared.run(method: "tabs.open", deadline: .now + .seconds(10)) { @MainActor in
            for await found in Observations({ services.locateTab(surface: surface) != nil }) where found { return true }
            return false
        }
        guard appeared == true, let tab = services.locateTab(surface: surface) else {
            throw AutomationTabError.unavailable
        }
        return tab
    }

    /// Where a session's new tab goes: the active window's focused pane;
    /// else, when the window shows a page (Home, History: its workspace is
    /// parked, so no pane is focused), the default pane of the shown screen
    /// of the workspace under the page, the fallback `cmux browser open`
    /// uses (9d300f272470). The window keeps showing the page. Never an
    /// incognito pane, never another machine's workspace.
    private func sessionTabPane(_ browserTabs: BrowserTabService) throws(AutomationTabError) -> PaneID {
        guard let services, let window = services.windows.active else { throw .noPane }
        let pane: PaneID
        if let focused = window.focusedPane {
            pane = focused.pane.handle
        } else {
            let state = window.state
            guard state.machineID == MachineRegistry.localID, let id = state.workspaceID,
                  let workspace = services.daemon.store.workspaces.first(where: { $0.id == id }) else { throw .noPane }
            let screen = workspace.screens.first { $0.id == state.activeScreenID } ?? workspace.screens.first
            guard let model = screen.flatMap({ $0.defaultPane.flatMap($0.pane) ?? $0.panes.first }) else { throw .noPane }
            pane = model.handle
        }
        guard !browserTabs.isIncognitoPane(pane) else { throw .noPane }
        return pane
    }

    /// A WebKit tab no pane shows moves its chrome into an off-screen render
    /// window before a driver call (``AgentRenderWindows``); a pane that
    /// shows it later takes it back.
    func keepRendering(_ tab: WebKitTab) async -> Bool {
        guard let services, let entry = services.cache.existingBrowser(tab.id.rawValue), (entry.tab as? WebKitTab) === tab else { return false }
        return renderWindows.keepRendering(tabID: tab.id.rawValue, chrome: entry.chrome, webView: tab.webView)
    }

    /// Tabs belong to the person's layout: the provider never closes one.
    func closeAutomationTab(_ id: BrowserTabID) {}

    /// The one exception: a browser session's end closes the tabs it created and did not keep
    /// (the host filters out kept, person-driven and paused tabs). It is a normal store close
    /// (`close-tabs`), marked `session_end` so Reopen Closed leaves it out; an older daemon
    /// without `close-reason-v1` keeps the tab (never an unmarked close). The host decides which
    /// tabs a session created and that no person holds (gap: the store does not check it).
    func endSessionTab(_ id: String) -> Bool {
        guard let services, let tab = localBrowserTabs.first(where: { $0.model.id == id })?.model else { return false }
        let daemon = services.daemon
        guard daemon.supports(DaemonCapabilities.shared.closeReason) else { return false }
        let surface = tab.surface
        let cache: TabContentCache = services.cache
        // task-owner: one store close; the page goes with it, as after a person's close
        Task {
            let closed = await daemon.run(CloseTabsRequest.command) { connection in
                _ = try await connection.closeTabs([surface], endTerminals: false, reason: .sessionEnd)
            }
            if closed { cache.release(id) }
        }
        return true
    }

    /// Selecting a tab changes the person's view: not through the provider.
    func activateAutomationTab(_ id: BrowserTabID) {}
}

/// Agent-facing protocol text (driver error message), not shown to a person: not localized.
enum AutomationTabError: LocalizedError {
    /// No daemon browser tabs, or the new tab did not appear.
    case unavailable
    /// No window with a pane to hold the tab (or only an incognito one).
    case noPane
    /// A Chromium session's tab, and Chromium cannot open tabs (why).
    case chromiumUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "the app cannot open a browser tab now"
        case .noPane: "the app has no window with a pane for a new tab"
        case .chromiumUnavailable(let reason): "Chromium cannot open a tab: \(reason)"
        }
    }
}
