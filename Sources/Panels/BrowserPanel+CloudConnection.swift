import Foundation
import WebKit

extension BrowserPanel {
    func installCloudDesktopConnectionObserver(on webView: WKWebView) {
        let isCurrent = webViewObservationValidator(for: webView)
        CloudDesktopConnectionObserver.install(on: webView) { [weak self] url, state in
            guard let self, isCurrent() else { return }
            self.applyCloudDesktopRecovery(self.cloudAccess.desktopConnectionDidChange(url: url, state: state))
        }
    }

    /// The shared route reported a new phase. A replaced carrier leaves the
    /// live document dialing a loopback port that no longer exists, so the
    /// document is rebound here rather than waiting for a URL to change.
    func cloudDesktopRouteDidChange() {
        applyCloudDesktopRecovery(cloudAccess.desktopRouteDidChange())
    }

    private func applyCloudDesktopRecovery(_ action: CloudDesktopRecoveryPolicy.Action) {
        switch action {
        case .resolveEndpoint:
            // Re-resolve the machine's carrier from its stable identity, but
            // only if the bound one has stopped answering. A replaced carrier
            // arrives back here as a route change.
            cloudAccess.resolveDesktopCarrierIfGone()
        case .rebind:
            rebindCloudDesktopRoute()
        case .idle:
            break
        }
    }

    /// Re-apply the carrier's credentials and rebuild the document. The
    /// injected WebSocket bridge only runs at document start, so the live page
    /// has to load again before it can reach the new port and token. The
    /// machine's X session and the applications running in it are untouched,
    /// and no additional Desktop surface is created.
    private func rebindCloudDesktopRoute() {
        guard let url = cloudAccess.navigationURL ?? cloudAccess.remoteURL else { return }
        // Navigating re-applies the carrier credentials and loads a new
        // document in one step. reload() routes Cloud panes through
        // cloudAccess.retry(), which restarts the shared route and clears the
        // recovery budget that keeps this from becoming a reload loop.
        navigate(to: url)
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let serviceURL = cloudAccess.sessionURL(currentURL: currentURL) { return serviceURL.absoluteString }
        if let displayURL = restorableDisplayURLForCurrentErrorPage(liveURL: webView.url),
           let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }
}
