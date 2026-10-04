import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextBrowserHost
import CmuxNextDaemon
import Foundation

/// The app's browser tabs for the browser host: the tab list (`hello`,
/// `tab.announced`/`navigated`/`gone`), each Chromium tab's extension access
/// (`tab.access`), the WebKit driver's tab provider, and the agent mark.
///
/// Only the local daemon's workspaces, and no incognito tab: agents on this
/// machine drive tabs this machine's store owns. The getters read the store
/// and the live pages, which are observable, plus `pageInstalls` (a page was
/// created); visibility is pushed with `refreshTabs()`.
final class AppBrowserHostTabs: ProviderTabSource, ProviderAccessSource, AutomationTabProvider, ProviderAgentMarking {
    private weak var services: AppServices?
    /// Extension access depends on manifests read from disk: computed again
    /// only when the profile's extension list or the page URL changes.
    private var accessMemo: [String: (extensions: [BrowserExtensionInfo], url: URL?, names: [String])] = [:]

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

    /// The host opens tabs through `openBrowser` (store op), never through
    /// the provider, for both engines.
    func openAutomationTab(url: URL?) async throws -> WebKitTab {
        throw AutomationTabError.openThroughStore
    }

    /// Tabs belong to the person's layout: the provider never closes one.
    func closeAutomationTab(_ id: BrowserTabID) {}

    /// Selecting a tab changes the person's view: not through the provider.
    func activateAutomationTab(_ id: BrowserTabID) {}
}

/// Agent-facing protocol text (driver error message), not shown to a person: not localized.
enum AutomationTabError: LocalizedError {
    case openThroughStore

    var errorDescription: String? {
        "opening a tab through the app provider is not supported; open it with openBrowser (cmux browser open) and use its targetId"
    }
}
