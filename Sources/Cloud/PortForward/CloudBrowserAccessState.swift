import Foundation
import CmuxCore
import Observation

/// Decides when a Cloud Desktop viewer that lost its session needs its
/// authenticated route rebound, rather than being left to noVNC's own retry.
///
/// The desktop page reaches its machine through a per-VM browser carrier. That
/// carrier's loopback port and WebSocket token are injected into the document
/// when it loads, and noVNC's built-in `reconnect=1` retry reuses whatever the
/// document was built with. Once the carrier is replaced, every retry dials a
/// port that no longer exists. The document went stale, not the URL: the page
/// URL is the machine's private address, which is identical across carrier
/// restarts, so URL-comparing navigation never re-navigates and the injected
/// credentials are never refreshed.
///
/// Recovery is therefore driven by an observed endpoint change, never by a
/// timer: at most one endpoint re-resolve per disconnected episode, and a
/// reload only when the resolved endpoint actually differs from the one the
/// live document carries.
struct CloudDesktopRecoveryPolicy: Equatable {
    enum Action: Equatable {
        /// Ask the shared route for its current carrier endpoint.
        case resolveEndpoint
        /// Re-apply the carrier credentials and reload the viewer once.
        case rebind
        /// Nothing to do. Named so it cannot be confused with `Optional.none`.
        case idle
    }

    /// Consecutive rebinds allowed without the viewer reaching `connected`.
    /// Past this the endpoint is demonstrably not what is broken, so the
    /// failure is surfaced instead of reloading the document again.
    static let rebindLimit = 3

    private(set) var boundEndpoint: CloudBrowserProxyEndpoint?
    private(set) var rebindsWithoutConnection = 0
    private var didRequestResolve = false

    /// True once repeated rebinds have failed to restore a session, so the
    /// pane reports a real failure instead of presenting another retry.
    var hasExhaustedRebinds: Bool { rebindsWithoutConnection >= Self.rebindLimit }

    /// The viewer committed a document built with `endpoint`.
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

    /// `endpoint` is read from the shared route at call time, so a late
    /// callback cannot reintroduce an endpoint a recovered session replaced.
    mutating func routeDidChange(currentEndpoint endpoint: CloudBrowserProxyEndpoint?) -> Action {
        guard let endpoint, let bound = boundEndpoint, endpoint != bound,
              !hasExhaustedRebinds else { return .idle }
        boundEndpoint = endpoint
        didRequestResolve = false
        rebindsWithoutConnection += 1
        return .rebind
    }

    mutating func reset() { self = CloudDesktopRecoveryPolicy() }
}

/// Browser-owned navigation state, separate from the shared VM-port choice.
/// Failed loads keep the native connection controls visible in the same pane.
@MainActor
@Observable
final class CloudBrowserAccessState {
    var model: CloudPortAccessModel?
    private(set) var remoteURL: URL?
    private(set) var navigationURL: URL?
    private(set) var hasCommittedNavigation = false
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var desktopConnection: CloudDesktopConnectionState?
    private var recovery = CloudDesktopRecoveryPolicy()
    @ObservationIgnored private var desktopCarrierProbe: Task<Void, Never>?
    private var dismissedFailure: String?
    var showsPorts = true
    private(set) var unavailable: String?

    func showUnavailable(_ message: String) {
        leave()
        unavailable = message
    }

    /// A desktop whose viewer is not connected drops every click and drag,
    /// so its last framebuffer is never presented as a working page.
    var showsPage: Bool {
        model?.isReady == true && loaded && error == nil && desktopConnection?.isConnected != false
    }

    /// The viewer lost its session and is retrying. Genuine state, not yet a failure.
    var desktopStatusMessage: String? {
        guard let desktopConnection, !desktopConnection.isConnected, desktopFailure == nil else { return nil }
        return String(localized: "cloud.portAccess.desktopReconnecting", defaultValue: "Reconnecting to the Cloud desktop\u{2026}")
    }

    /// Repeated rebinds onto fresh carriers did not restore a session, so the
    /// endpoint is not what is broken and the pane reports a real failure.
    var desktopFailure: String? {
        guard let desktopConnection else { return nil }
        guard desktopConnection == .failed || (!desktopConnection.isConnected && recovery.hasExhaustedRebinds) else { return nil }
        return String(localized: "cloud.portAccess.desktopDisconnected", defaultValue: "The Cloud desktop connection failed. Retry to reconnect to the machine.")
    }

    /// A Cloud document can commit before its render-blocking resources arrive.
    /// Use the pane's backing color through that initial load for every origin;
    /// after load WebKit resumes its ordinary document background semantics.
    var isPreparingDocument: Bool { model != nil && !loaded && failureMessage == nil }

    var isDesktop: Bool {
        model?.target.port == CmuxTuiSnapshotParser.desktopPort && remoteURL?.path == "/vnc.html"
    }

    var failureMessage: String? {
        if let error = desktopFailure ?? error ?? unavailable { return error }
        if case .failed(let message)? = model?.phase { return message }
        return nil
    }

    var showsFailureAlert: Bool {
        failureMessage.map { $0 != dismissedFailure } ?? false
    }

    func dismissFailure() { dismissedFailure = failureMessage }

    /// noVNC's document may finish loading before its RFB/WebSocket fails.
    /// Only the current, committed Cloud Desktop document may report its state.
    @discardableResult
    func desktopConnectionDidChange(url: URL, state: CloudDesktopConnectionState) -> CloudDesktopRecoveryPolicy.Action {
        guard isDesktop, hasCommittedNavigation,
              let navigationURL, url == navigationURL else { return .idle }
        desktopConnection = state
        if state.isConnected { dismissedFailure = nil }
        return recovery.viewerDidReport(state)
    }

    /// The shared route's carrier may have been replaced. Read its endpoint
    /// now rather than trusting a captured one, so a late callback from an
    /// obsolete attempt cannot reintroduce the endpoint a recovery replaced.
    @discardableResult
    func desktopRouteDidChange() -> CloudDesktopRecoveryPolicy.Action {
        guard isDesktop else { return .idle }
        return recovery.routeDidChange(currentEndpoint: model?.browserProxy)
    }

    /// The viewer lost its session. Re-resolve the machine's carrier only when
    /// the one this document is bound to has actually stopped answering: a
    /// carrier that still responds is not what broke input, and restarting the
    /// shared route would interrupt other panes on the same machine.
    func resolveDesktopCarrierIfGone() {
        guard let model, let endpoint = model.browserProxy else { return }
        let target = model.target
        desktopCarrierProbe?.cancel()
        desktopCarrierProbe = Task { [weak self] in
            let reachable = (try? await CloudBrowserRouting.desktopIsReachable(
                endpoint: endpoint, address: target.host, port: target.port
            )) ?? false
            guard !Task.isCancelled, let self, self.model === model,
                  model.browserProxy == endpoint,
                  self.desktopConnection?.isConnected == false,
                  !reachable else { return }
            model.connectBrowser(force: true)
        }
    }

    private func cancelDesktopCarrierProbe() {
        desktopCarrierProbe?.cancel()
        desktopCarrierProbe = nil
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

    func configure(model: CloudPortAccessModel, url: URL) {
        unavailable = nil
        self.model = model
        remoteURL = url
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopConnection = nil
        recovery.reset()
        cancelDesktopCarrierProbe()
        dismissedFailure = nil
    }

    func nextURL() -> URL? {
        guard let remoteURL, let url = model?.url(for: remoteURL) else {
            navigationURL = nil
            loaded = false
            return nil
        }
        guard navigationURL != url else { return nil }
        navigationURL = url
        hasCommittedNavigation = false
        error = nil
        loaded = false
        return url
    }

    func didStart(url: URL?) {
        guard let url, owns(url), navigationURL != nil else { return }
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopConnection = nil
        dismissedFailure = nil
    }

    func didCommit(url: URL?) {
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
        // The document now carries this carrier's port and WebSocket token.
        if isDesktop { recovery.documentDidBind(to: model?.browserProxy) }
    }

    func didFinish(url: URL?) {
        guard let url, navigationURL != nil, hasCommittedNavigation, url.scheme != "about", error == nil else { return }
        loaded = true
        error = nil
    }

    func didFail(url: URL?, message: String) {
        guard let url, navigationURL != nil, owns(url) else { return }
        loaded = false
        error = message
    }

    func retry() {
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopConnection = nil
        recovery.reset()
        cancelDesktopCarrierProbe()
        dismissedFailure = nil
        model?.retry()
    }

    func owns(_ url: URL) -> Bool {
        guard let remoteURL else { return false }
        if model?.usesBrowserProxy == true {
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.lowercased() == remoteURL.host?.lowercased()
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
        unavailable = nil
        model = nil
        remoteURL = nil
        navigationURL = nil
        loaded = false
        error = nil
        desktopConnection = nil
        recovery.reset()
        cancelDesktopCarrierProbe()
        dismissedFailure = nil
    }

    private static func sameService(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
}
