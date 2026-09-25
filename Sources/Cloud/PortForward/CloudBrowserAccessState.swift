import CmuxSurfaceCatalogModel
import Foundation
import CmuxCore
import CmuxFoundation
import Observation
import OSLog

private let cloudDisplayLogger = Logger(subsystem: "com.cmuxterm.app", category: "CloudDisplayConnection")

/// Bounds Cloud Desktop route recovery to one re-resolve per disconnect episode.
struct CloudDesktopRecoveryPolicy: Equatable {
    enum Action: Equatable { case resolveEndpoint, rebind, idle }
    static let rebindLimit = 3
    private(set) var boundEndpoint: CloudBrowserProxyEndpoint?
    private(set) var rebindsWithoutConnection = 0
    private var didRequestResolve = false
    var hasExhaustedRebinds: Bool { rebindsWithoutConnection >= Self.rebindLimit }

    mutating func documentDidBind(to endpoint: CloudBrowserProxyEndpoint?) {
        boundEndpoint = endpoint
        didRequestResolve = false
    }

    mutating func viewerDidReport(_ state: CloudDesktopConnectionState) -> Action {
        guard !state.isConnected else {
            didRequestResolve = false
            rebindsWithoutConnection = 0
            return .idle
        }
        guard boundEndpoint != nil, !didRequestResolve, !hasExhaustedRebinds else { return .idle }
        didRequestResolve = true
        return .resolveEndpoint
    }

    mutating func routeDidChange(currentEndpoint endpoint: CloudBrowserProxyEndpoint?) -> Action {
        guard let endpoint, let boundEndpoint, endpoint != boundEndpoint, !hasExhaustedRebinds else { return .idle }
        self.boundEndpoint = endpoint
        didRequestResolve = false
        rebindsWithoutConnection += 1
        return .rebind
    }

    mutating func reset() { self = Self() }
}

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
    private(set) var desktopConnection: CloudDesktopConnectionState?
    private var recovery = CloudDesktopRecoveryPolicy()
    @ObservationIgnored private var desktopCarrierProbe: Task<Void, Never>?
    private(set) var documentIdentity = UUID().uuidString
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

    /// Rebinds ownership to a committed same-VM service without restarting the
    /// current WebKit navigation (for example, a POST redirect to another port).
    func adoptCommittedRoute(model: CloudPortAccessModel, url: URL, resourceID: SurfaceResourceID) {
        observationGeneration &+= 1
        unavailable = nil
        self.resourceID = resourceID
        self.model = model
        remoteURL = url
        navigationURL = nil
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
        activeNavigationID = nil
        connectionDeadline.cancel()
        trace("route_adopted")
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

    var showsPage: Bool {
        model?.isReady == true && loaded && error == nil && desktopConnection?.isConnected != false
    }

    var desktopStatusMessage: String? {
        guard let desktopConnection, !desktopConnection.isConnected, desktopFailure == nil else { return nil }
        return String(localized: "cloud.portAccess.desktopReconnecting", defaultValue: "Reconnecting to the Cloud desktop\u{2026}")
    }

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
        _ = desktopConnectionDidChange(url: url, state: isConnected ? .connected : .failed)
    }

    @discardableResult
    func desktopConnectionDidChange(
        url: URL,
        state: CloudDesktopConnectionState,
        documentIdentity: String? = nil
    ) -> CloudDesktopRecoveryPolicy.Action {
        guard isDesktop, hasCommittedNavigation,
              let navigationURL, url == navigationURL,
              documentIdentity.map({ $0 == self.documentIdentity }) ?? true else { return .idle }
        desktopConnection = state
        let isConnected = state.isConnected
        if isConnected {
            connectionDeadline.cancel()
            loaded = true
            error = nil
            desktopFailure = nil
            dismissedFailure = nil
        } else {
            connectionDeadline.cancel()
            if state == .failed || recovery.hasExhaustedRebinds {
                desktopFailure = String(localized: "cloud.portAccess.desktopDisconnected", defaultValue: "The Cloud desktop connection failed. Retry to reconnect to the machine.")
            } else {
                desktopFailure = nil
            }
        }
        desktopConnected = isConnected
        trace(isConnected ? "rfb_connected" : "rfb_failed")
        return recovery.viewerDidReport(state)
    }

    func desktopConnectionIsConnecting(url: URL) {
        guard isDesktop, hasCommittedNavigation, url == navigationURL else { return }
        desktopConnected = false
        desktopConnection = .reconnecting
        desktopFailure = nil
        dismissedFailure = nil
        startDeadline()
    }

    @discardableResult
    func desktopRouteDidChange() -> CloudDesktopRecoveryPolicy.Action {
        guard isDesktop else { return .idle }
        return recovery.routeDidChange(currentEndpoint: model?.browserProxy)
    }

    func resolveDesktopCarrierIfGone() {
        guard let model, let endpoint = model.browserProxy else { return }
        let target = model.target
        desktopCarrierProbe?.cancel()
        desktopCarrierProbe = Task { [weak self] in
            let reachable = (try? await CloudBrowserRouting.desktopIsReachable(
                endpoint: endpoint, address: target.host, port: target.port
            )) ?? false
            guard !Task.isCancelled, let self, self.model === model,
                  model.browserProxy == endpoint, self.desktopConnection?.isConnected == false,
                  !reachable else { return }
            model.connectBrowser(force: true)
        }
    }

    func beginDesktopNavigationIdentity() -> String {
        documentIdentity = UUID().uuidString
        return documentIdentity
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
        desktopConnection = nil
        recovery.reset()
        documentIdentity = UUID().uuidString
        desktopCarrierProbe?.cancel()
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
        desktopConnected = false
        desktopConnection = nil
        recovery.reset()
        documentIdentity = UUID().uuidString
        startDeadline()
        loaded = false
        trace("route_ready")
        return url
    }

    func didStart(url: URL?, navigationID: ObjectIdentifier? = nil) {
        guard let url, navigationURL != nil else { return }
        activeNavigationID = navigationID
        if isDesktop { documentIdentity = UUID().uuidString }
        guard owns(url) else { return }
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
        if isDesktop { recovery.documentDidBind(to: model?.browserProxy) }
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
        desktopConnection = nil
        desktopCarrierProbe?.cancel()
        recovery.reset()
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
        desktopConnection = nil
        desktopCarrierProbe?.cancel()
        recovery.reset()
        documentIdentity = UUID().uuidString
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
