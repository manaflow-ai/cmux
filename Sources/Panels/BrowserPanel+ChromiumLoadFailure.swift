import CmuxBrowser
import Foundation

/// A Chromium main-frame load failure Chromium drew no page for.
struct ChromiumLoadFailure: Equatable {
    /// Chromium's error.
    let error: ChromiumNetError
    /// The address that failed, if Chromium reported one.
    let url: URL?
}

/// Load failures of a non-WebKit (Chromium) page.
///
/// Chromium draws its own page for most failures ("This site can't be
/// reached", its certificate interstitial), and cmux shows nothing over it.
/// Where Chromium's page is empty (a certificate error in an agent-driven
/// tab, which the shim cancels; ERR_INVALID_AUTH_CREDENTIALS) the pane shows
/// cmux's recovery view with Reload, and Proceed for a certificate error, as
/// cmux Next shows `LoadErrorView`. Either way the address bar shows the
/// address that failed until the next load starts.
extension BrowserPanel {
    /// A non-WebKit page's main-frame load failed.
    func applyEnginePageNavigationFailure(url: URL?, code: Int, message: String, showsEngineErrorPage: Bool) {
        let error = ChromiumNetError(code: code, text: message)
        switch error.presentation(chromiumShowsPage: showsEngineErrorPage) {
        case .nothing:
            // A load a newer one replaced, or a stop: not a failure to show.
            return
        case .chromiumPage:
            chromiumLoadFailure = nil
        case .cmuxPage:
            chromiumLoadFailure = ChromiumLoadFailure(error: error, url: url)
        }
        guard let url, url.absoluteString != blankURLString else { return }
        engineFailedNavigationURL = url
        if currentURL != url { currentURL = url }
    }

    /// The non-WebKit page started a load: the failure it replaces is over.
    func noteEngineLoadStarted() {
        chromiumLoadFailure = nil
        engineFailedNavigationURL = nil
    }

    /// Whether the recovery view offers Proceed: a certificate error on a
    /// page that can answer it. Only a person can press it (native UI).
    var canProceedPastChromiumLoadFailure: Bool {
        guard let failure = chromiumLoadFailure, failure.error.isCertificateError, failure.url?.host() != nil else {
            return false
        }
        return enginePage is any BrowserPageCertificateBypassing
    }

    /// Reload on the recovery view: loads the failed address again (the
    /// page's own reload would reload the page the failed load left).
    func retryChromiumLoadFailure() {
        guard let url = chromiumLoadFailure?.url, url.absoluteString != blankURLString else {
            _ = reload()
            return
        }
        takeBrowserDialogOwnership(.user)
        navigateWithoutInsecureHTTPPrompt(request: URLRequest(url: url), recordTypedNavigation: false)
    }

    /// Proceed on the recovery view's certificate warning: Chromium continues
    /// past the error on that host (or leaves it to its own interstitial,
    /// which knows the host's HSTS state) and loads the page again.
    func proceedPastChromiumLoadFailure() {
        guard canProceedPastChromiumLoadFailure, let failure = chromiumLoadFailure, let url = failure.url,
              let page = enginePage as? any BrowserPageCertificateBypassing else { return }
        takeBrowserDialogOwnership(.user)
        page.proceedPastCertificateError(failure.error, at: url)
    }

    /// Restores history a non-WebKit page exported before (Reopen Closed
    /// Tab) in place of loading `displayURL` fresh.
    /// - Returns: `false` when the page cannot restore it; the caller loads
    ///   the address instead.
    func restoreEngineNavigation(_ state: BrowserPageRestoreState, displayURL: URL?) -> Bool {
        guard let enginePage, state.engineKind == enginePage.engineKind,
              let page = enginePage as? any BrowserPageNavigationRestoring,
              page.restoreNavigation(state) else { return false }
        shouldRenderWebView = true
        if let displayURL { currentURL = displayURL }
        return true
    }
}
