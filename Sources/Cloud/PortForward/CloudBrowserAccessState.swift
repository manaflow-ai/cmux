import Foundation
import CmuxCore
import CmuxFoundation
import Observation
import OSLog

private let cloudDisplayLogger = Logger(subsystem: "com.cmuxterm.app", category: "CloudDisplayConnection")

/// Browser-owned navigation state, separate from the shared VM-port choice.
/// Failed loads keep the native connection controls visible in the same pane.
@MainActor
@Observable
final class CloudBrowserAccessState {
    var model: CloudPortAccessModel?
    private(set) var resourceID: SurfaceResourceID?
    private(set) var remoteURL: URL?
    private(set) var navigationURL: URL?
    private(set) var hasCommittedNavigation = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var desktopFailure: String?
    private var dismissedFailure: String?
    var showsPorts = true
    private(set) var unavailable: String?
    private(set) var desktopConnected = false
    @ObservationIgnored private let connectionDeadline: MainActorDeferredActionScheduler
    @ObservationIgnored private var navigate: (@MainActor (URL) -> Void)?
    @ObservationIgnored private var observationGeneration: UInt64 = 0
    private var activeNavigationID: ObjectIdentifier?
    @ObservationIgnored private let logID = UUID().uuidString
    @ObservationIgnored private var attempt = 0

    init(clock: any Clock<Duration> = ContinuousClock()) {
        connectionDeadline = MainActorDeferredActionScheduler(clock: clock)
    }

    /// Route readiness belongs to the browser, including while its SwiftUI host
    /// is hidden. Observe the current value again after every transition so a
    /// cached retry cannot lose a connecting → ready change to view coalescing.
    func automaticallyNavigate(_ action: @escaping @MainActor (URL) -> Void) {
        navigate = action
        observeRoute()
    }

    func routeDidConfigure() { observeRoute() }
    func retainResource(_ resource: SurfaceResourceID) { resourceID = resource }

    private func observeRoute() {
        observationGeneration &+= 1
        let generation = observationGeneration
        guard let model, navigate != nil else { return }
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.observeRoute()
            }
        }
        if let url = nextURL() { navigate?(url) }
    }

    private func trace(_ event: String) {
        cloudDisplayLogger.debug("Display state: id=\(self.logID, privacy: .public) attempt=\(self.attempt) event=\(event, privacy: .public) ready=\(self.model?.isReady == true) committed=\(self.hasCommittedNavigation) loaded=\(self.loaded) connected=\(self.desktopConnected)")
    }

    private func startDeadline() {
        guard isDesktop, !connectionDeadline.isScheduled else { return }
        connectionDeadline.schedule(after: .seconds(45)) { [weak self] in
            guard let self, self.isDesktop, !self.desktopConnected, self.failureMessage == nil else { return }
            self.desktopFailure = String(localized: "cloud.display.connectionTimedOut", defaultValue: "The Cloud display did not connect within 45 seconds. Retry to reconnect.")
            self.trace("deadline")
        }
    }

    func showUnavailable(_ message: String) {
        let retainedResource = resourceID
        leave()
        resourceID = retainedResource
        unavailable = message
    }

    var showsPage: Bool { model?.isReady == true && loaded && error == nil }

    /// A Cloud document can commit before its render-blocking resources arrive.
    /// Use the pane's backing color through that initial load for every origin;
    /// after load WebKit resumes its ordinary document background semantics.
    var isPreparingDocument: Bool { model != nil && !loaded && failureMessage == nil }

    var isDesktop: Bool {
        if resourceID?.kind == .display { return true }
        guard resourceID == nil else { return false }
        return model?.target.port == CmuxTuiSnapshotParser.desktopPort && remoteURL?.path == "/vnc.html"
    }

    var failureMessage: String? {
        if let error = desktopFailure ?? error ?? unavailable { return error }
        if case .failed(let message)? = model?.phase { return message }
        return nil
    }

    /// A failed Cloud placeholder still owns its resource. A browser that has
    /// deliberately navigated away has called `leave()` and must duplicate its
    /// current page as an ordinary browser instead of resurrecting that stale
    /// Cloud projection.
    var retainsCloudResourceForDuplication: Bool {
        model != nil || resourceID?.machine.isLocal == false
    }

    var showsFailureAlert: Bool {
        failureMessage.map { $0 != dismissedFailure } ?? false
    }

    func dismissFailure() { dismissedFailure = failureMessage }

    /// noVNC's document may finish loading before its RFB/WebSocket fails.
    /// Only the current, committed Cloud Desktop document may report its state.
    func desktopConnectionDidChange(url: URL, isConnected: Bool) {
        guard isDesktop, hasCommittedNavigation,
              let navigationURL, url == navigationURL else { return }
        if isConnected {
            connectionDeadline.cancel()
            loaded = true
            error = nil
            desktopFailure = nil
            dismissedFailure = nil
        } else {
            connectionDeadline.cancel()
            desktopFailure = String(localized: "cloud.portAccess.desktopDisconnected", defaultValue: "The Cloud desktop connection failed. Retry to reconnect to the machine.")
        }
        desktopConnected = isConnected
        trace(isConnected ? "rfb_connected" : "rfb_failed")
    }

    func desktopConnectionIsConnecting(url: URL) {
        guard isDesktop, hasCommittedNavigation, url == navigationURL else { return }
        desktopConnected = false
        desktopFailure = nil
        dismissedFailure = nil
        startDeadline()
    }

    /// Persist the service identity; the local listener only lives for this app run.
    func sessionURL(currentURL: URL?) -> URL? {
        guard let remoteURL else { return nil }
        guard let currentURL, currentURL.scheme != "about" else { return remoteURL }
        guard owns(currentURL) else { return navigationURL == nil ? remoteURL : nil }
        guard var parts = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) else { return remoteURL }
        parts.host = remoteURL.host
        parts.port = remoteURL.port
        parts.scheme = remoteURL.scheme
        return parts.url ?? remoteURL
    }

    /// A bootstrap document belongs to WebKit, not to the user's navigation.
    /// Keep the requested Cloud origin until a real service document commits.
    func displayURL(_ observedURL: URL?) -> URL? {
        guard let remoteURL, !hasCommittedNavigation,
              observedURL == nil || observedURL?.scheme == "about" else { return nil }
        return remoteURL
    }

    func configure(model: CloudPortAccessModel, url: URL, resourceID: SurfaceResourceID? = nil) {
        observationGeneration &+= 1
        unavailable = nil
        // WebView/profile replacement reconfigures the existing route without
        // passing the identity again. Keep the stable display ID until an
        // explicit replacement supplies a new one; callers that leave Cloud
        // first still clear it deliberately.
        if let resourceID {
            self.resourceID = resourceID
        }
        self.model = model
        remoteURL = url
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
        desktopConnected = false
        activeNavigationID = nil
        connectionDeadline.cancel()
        startDeadline()
        attempt += 1
        trace("configured")
        // Reconfiguration invalidates the previous observation generation.
        // Re-arm it even when the same access model is reused by a WebView
        // replacement that is still waiting for its route to become ready.
        observeRoute()
    }

    func nextURL() -> URL? {
        guard let remoteURL, let url = model?.url(for: remoteURL) else {
            hasCommittedNavigation = false
            desktopConnected = false
            navigationURL = nil
            loaded = false
            return nil
        }
        guard navigationURL != url else { return nil }
        navigationURL = url
        hasCommittedNavigation = false
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
        startDeadline()
        loaded = false
        trace("route_ready")
        return url
    }

    func didStart(url: URL?, navigationID: ObjectIdentifier? = nil) {
        guard let url, owns(url), navigationURL != nil else { return }
        activeNavigationID = navigationID
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
        desktopConnected = false
        startDeadline()
        trace("navigation_started")
    }

    func didCommit(url: URL?, navigationID: ObjectIdentifier? = nil) {
        guard navigationID == nil || navigationID == activeNavigationID else { return }
        guard let url, navigationURL != nil else { return }
        guard owns(url) else {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { leave() }
            return
        }
        if model?.usesBrowserProxy == true {
            remoteURL = url
            navigationURL = url
        }
        hasCommittedNavigation = true
        trace("navigation_committed")
    }

    func didFinish(url: URL?) {
        guard let url, navigationURL != nil, hasCommittedNavigation, owns(url), url.scheme != "about", error == nil else { return }
        loaded = true
        error = nil
        trace("navigation_finished")
    }

    func didFail(url: URL?, message: String, navigationID: ObjectIdentifier? = nil) {
        guard navigationID == nil || navigationID == activeNavigationID else { return }
        guard let url, navigationURL != nil, owns(url) else { return }
        loaded = false
        error = message
        hasCommittedNavigation = false
        activeNavigationID = nil
        desktopConnected = false
        connectionDeadline.cancel()
        trace("navigation_failed")
    }

    func didCancel(navigationID: ObjectIdentifier? = nil) {
        guard model != nil, !loaded, navigationURL != nil,
              navigationID == nil || navigationID == activeNavigationID else { return }
        connectionDeadline.cancel()
        error = String(localized: "cloud.display.connectionCancelled", defaultValue: "The Cloud page connection was cancelled. Retry to connect.")
        hasCommittedNavigation = false
        activeNavigationID = nil
        desktopConnected = false
        trace("navigation_cancelled")
    }

    func retry() {
        attempt += 1
        trace("retry")
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
        desktopConnected = false
        activeNavigationID = nil
        connectionDeadline.cancel()
        startDeadline()
        model?.retry()
        observeRoute()
    }

    func owns(_ url: URL) -> Bool {
        guard let remoteURL else { return false }
        if model?.usesBrowserProxy == true {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.lowercased() == remoteURL.host?.lowercased() else { return false }
            if let resourceID, let expectedPort = Self.resourcePort(for: resourceID) {
                let requestedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
                return requestedPort == expectedPort
            }
            return true
        }
        return Self.sameService(url, remoteURL) || navigationURL.map { Self.sameService(url, $0) } == true
    }

    /// Explicit localhost links within a VM page keep that page's VM as their owner.
    func rewrittenLoopbackURL(_ url: URL) -> URL? {
        guard model?.usesBrowserProxy == true, let remoteURL,
              RemoteLoopbackProxyAlias.isLoopbackHost(url.host ?? ""),
              let address = remoteURL.host else { return nil }
        return CloudPortRoutePlan.privateURL(url.absoluteString, address: address)
    }

    func leave() {
        observationGeneration &+= 1
        navigate = nil
        connectionDeadline.cancel()
        desktopConnected = false
        resourceID = nil
        activeNavigationID = nil
        hasCommittedNavigation = false
        unavailable = nil
        model = nil
        remoteURL = nil
        navigationURL = nil
        loaded = false
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
    }

    private static func sameService(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }

    private static func resourcePort(for resource: SurfaceResourceID) -> Int? {
        if resource.kind == .display,
           let number = Int(resource.key.split(separator: ":").last ?? ""),
           (1...16).contains(number) {
            return 6900 + number
        }
        if resource.kind == .browser, resource.key.hasPrefix("port:") {
            return Int(resource.key.dropFirst("port:".count))
        }
        return nil
    }
}
