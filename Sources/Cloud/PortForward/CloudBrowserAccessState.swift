import Foundation
import Observation

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
    private(set) var desktopFailure: String?
    private var dismissedFailure: String?
    var showsPorts = true
    private(set) var unavailable: String?

    func showUnavailable(_ message: String) {
        leave()
        unavailable = message
    }

    var showsPage: Bool { model?.isReady == true && loaded && error == nil }

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
    func desktopConnectionDidChange(url: URL, isConnected: Bool) {
        guard model?.target.port == CmuxTuiSnapshotParser.desktopPort,
              remoteURL?.path == "/vnc.html", hasCommittedNavigation,
              let navigationURL, url == navigationURL else { return }
        if isConnected {
            desktopFailure = nil
            dismissedFailure = nil
        } else {
            desktopFailure = String(localized: "cloud.portAccess.desktopDisconnected", defaultValue: "The Cloud desktop connection failed. Retry to reconnect to the machine.")
        }
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

    func configure(model: CloudPortAccessModel, url: URL) {
        unavailable = nil
        self.model = model
        remoteURL = url
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopFailure = nil
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
        desktopFailure = nil
        dismissedFailure = nil
    }

    func didCommit(url: URL?) {
        guard let url, owns(url), navigationURL != nil else { return }
        hasCommittedNavigation = true
    }

    func didFinish(url: URL?) {
        guard let url, navigationURL != nil, hasCommittedNavigation, url.scheme != "about", error == nil else { return }
        loaded = true
        error = nil
    }

    func didFail(url: URL?, message: String) {
        guard let url, let expected = navigationURL, url.absoluteString == expected.absoluteString else { return }
        loaded = false
        error = message
    }

    func retry() {
        navigationURL = nil
        hasCommittedNavigation = false
        loaded = false
        error = nil
        desktopFailure = nil
        dismissedFailure = nil
        model?.retry()
    }

    func owns(_ url: URL) -> Bool {
        guard let remoteURL else { return false }
        return Self.sameService(url, remoteURL) || navigationURL.map { Self.sameService(url, $0) } == true
    }

    func leave() {
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
}
