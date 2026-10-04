import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextBrowserHost
import Foundation

/// The app as the browser host's engine provider (plans/cmux-next/browser-host.md,
/// step c3): the provider bridge, the WebKit driver behind it, and the app's
/// tab, access, relay and agent-mark sources. The provider holds its sources
/// weakly; this object keeps them.
final class AppBrowserHost {
    let provider: BrowserHostProvider
    let driver: WebKitDriver
    private let credentials: AppProviderCredentials
    private let tabs: AppBrowserHostTabs
    private let relay: AppDevToolsRelay

    init(services: AppServices, installID: String = AppBrowserHost.installID()) {
        let tabs = AppBrowserHostTabs(services: services)
        let relay = AppDevToolsRelay(services: services, marking: tabs)
        let driver = WebKitDriver(provider: tabs)
        let credentials = AppProviderCredentials()
        self.credentials = credentials
        self.tabs = tabs
        self.relay = relay
        self.driver = driver
        provider = BrowserHostProvider(
            identity: ProviderIdentity(providerID: "cmux-app:\(services.environment.launch.bundleID)", installID: installID),
            credentials: credentials, tabs: tabs, access: tabs, driver: driver, relay: relay, marking: tabs)
        provider.onAgentBundle = { [driver] bundle, _ in
            // A new bundle: driven tabs install it again on their next call.
            guard driver.agentBundle != bundle else { return }
            driver.detach()
            driver.agentBundle = bundle
        }
        provider.onTabGone = { [driver] targetID in driver.tabClosed(BrowserTabID(rawValue: targetID)) }
    }

    func start() {
        provider.start()
    }

    /// One provider per install: a random id kept in the app's defaults.
    static func installID(defaults: UserDefaults = .standard) -> String {
        let key = "cmux.next.browserHost.installID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let id = "inst_" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }
}

/// The provider endpoint comes from the daemon's app-origin op
/// `browser.host.provider` (step c2), over the app's own daemon connection.
/// Until that op exists this answers nil, so the provider stays idle and
/// dials nothing.
final class AppProviderCredentials: ProviderCredentialsSource {
    func providerCredentials() async -> ProviderCredentials? { nil }
}
