import AppKit
import CmuxNextAgentCursor
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
    private weak var services: AppServices?
    /// Lease frames to every content's agent cursor (agent-cursor.md section 3).
    private let cursorLeases: AgentCursorLeaseFanOut
    private var leaseObservation: ProviderLeaseObservation?
    /// `input {event}` frames to the owning content's agent cursor (agent-cursor.md section 2).
    private let inputBridge: AgentCursorInputBridge
    private var inputObservation: ProviderInputObservation?
    private var inputLeaseObservation: ProviderLeaseObservation?

    init(services: AppServices, installID: String = AppBrowserHost.installID()) {
        self.services = services
        let tabs = AppBrowserHostTabs(services: services)
        let relay = AppDevToolsRelay(services: services, marking: tabs)
        relay.drivable = { [weak tabs] id in tabs?.isDrivable(id) ?? false }
        let driver = WebKitDriver(provider: tabs)
        let credentials = AppProviderCredentials()
        self.credentials = credentials
        self.tabs = tabs
        self.relay = relay
        self.driver = driver
        cursorLeases = AgentCursorLeaseFanOut(models: { [weak services] in
            guard let services else { return [] }
            return services.windows.controllers.flatMap { controller in
                (controller.parked + [controller.content].compactMap { $0 }).compactMap { $0.agentCursor?.model }
            }
        })
        inputBridge = AgentCursorInputBridge(
            publisher: { [weak services, weak tabs] targetID in
                guard let services, let workspaceID = tabs?.workspaceID(ofTab: targetID) else { return nil }
                return Self.owner(ofWorkspace: workspaceID, in: services)?.agentCursor?.publisher
            },
            publishers: { [weak services] in
                guard let services else { return [] }
                return services.windows.controllers.flatMap { controller in
                    (controller.parked + [controller.content].compactMap { $0 }).compactMap { $0.agentCursor?.publisher }
                }
            })
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
        leaseObservation = provider.observeLeases { [cursorLeases] targetID, lease in
            cursorLeases.leaseChanged(target: targetID, session: lease?.session, wireState: lease?.state)
        }
        inputObservation = provider.observeInputs { [inputBridge] event in
            guard let data = try? JSONSerialization.data(withJSONObject: event.foundationValue) else { return }
            inputBridge.receive(data)
        }
        inputLeaseObservation = provider.observeLeases { [inputBridge] targetID, lease in
            inputBridge.leaseChanged(target: targetID, session: lease?.session, wireState: lease?.state)
        }
    }

    /// Starts the provider (idle until step c2) and feeds it a person's key
    /// downs and scroll starts: before dispatch, when focus already names the
    /// page that gets them. A key down is reported before the key router
    /// runs, so an app shortcut pressed on a leased page also pauses the
    /// lease (accepted). A scroll counts only on the focused page. Clicks come
    /// from the app's mouse-down observer, after dispatch (focus has moved
    /// to the clicked page).
    func start() {
        provider.start()
        let application = NSApp as? CmuxApplication
        let earlier = application?.inputObserver
        application?.inputObserver = { [weak self] event in
            earlier?(event)
            if event.type == .keyDown || event.type == .scrollWheel { self?.noteInput(event) }
        }
    }

    /// A person's event reached a page: `user.input` when the page is leased.
    /// Only events AppKit dispatches come here; the WebKit driver calls the
    /// web view directly and CDP input stays inside Chromium, so agent input
    /// never pauses a lease.
    func noteInput(_ event: NSEvent) {
        let synthetic = (NSApp as? CmuxApplication)?.currentEventIsSynthetic ?? false
        guard ProviderUserInput.pausesLease(event, synthetic: synthetic),
              let window = CmuxApplication.accessibilityWindow(for: event.window ?? NSApp.keyWindow),
              let services, let controller = services.windows.controllers.first(where: { $0.window === window }),
              case .browserPage(_, let tab) = controller.focus.state.resolved else { return }
        provider.reportUserInput(event: event, synthetic: synthetic, targetID: tab)
    }

    /// The content that shows or parks `workspaceID`: its window's shown content first.
    static func owner(ofWorkspace workspaceID: String, in services: AppServices) -> WorkspaceContentController? {
        let controllers = services.windows.controllers
        if let shown = controllers.lazy.compactMap(\.content).first(where: { $0.workspace.id == workspaceID }) { return shown }
        return controllers.lazy.flatMap(\.parked).first { $0.workspace.id == workspaceID }
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
