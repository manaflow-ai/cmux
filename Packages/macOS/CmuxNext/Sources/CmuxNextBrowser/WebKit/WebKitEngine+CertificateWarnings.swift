import Foundation

/// Certificate warnings the user turned off by proceeding past them
/// (`certificateExceptions`, per profile, until the app quits), and turning
/// them on again from Page Info (Chrome's "Turn on warnings").
extension WebKitEngine {
    /// Whether the user proceeded past `host`'s certificate in `profile`.
    func hasCertificateException(_ host: String, profile: BrowserProfileID) -> Bool {
        certificateExceptions[profile]?.contains(host) ?? false
    }

    /// Forgets that the user proceeded past `host`'s certificate in
    /// `profile`; true when there was such a choice.
    @discardableResult
    func forgetCertificateException(host: String, profile: BrowserProfileID) -> Bool {
        guard certificateExceptions[profile]?.remove(host) != nil else { return false }
        certificateRechecks[profile, default: []].insert(host)
        return true
    }

    /// Called at each commit: a host being rechecked has the committed
    /// page's server trust evaluated (off the main thread); an untrusted one
    /// stops the page and shows the interstitial, a trusted one ends the
    /// recheck.
    func recheckCertificate(_ tab: WebKitTab) {
        guard let url = tab.webView.url, url.scheme?.lowercased() == "https", let host = url.host(),
              needsCertificateRecheck(host, profile: tab.profileID), let trust = tab.webView.serverTrust else { return }
        let box = ServerTrustBox(trust: trust)
        let profile = tab.profileID
        Task.detached { [weak self, weak tab] in
            let failure = box.evaluate()
            await MainActor.run {
                guard let self, let tab, tab.webView.url == url else { return }
                guard let failure else {
                    self.certificateRechecks[profile]?.remove(host)
                    return
                }
                tab.pageInfoActivity.recordCertificateFailure(chain: failure.chain, reason: failure.reason)
                tab.webView.stopLoading()
                let id = tab.allocateNavigationID()
                tab.apply(.started(id, url: url))
                tab.apply(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                                                       message: failure.reason ?? "", failingURL: url)))
            }
        }
    }

    /// The user proceeded past `host`'s certificate in `profile` (the
    /// interstitial's Proceed).
    func allowCertificateException(host: String, profile: BrowserProfileID) {
        certificateExceptions[profile, default: []].insert(host)
        certificateRechecks[profile]?.remove(host)
    }

    /// The next committed page of `host` in `profile` must have its server
    /// trust verified again: warnings were turned on again, and WebKit may
    /// reuse a kept-alive connection that was trusted by the old exception
    /// (no new TLS challenge, so the page would load without the warning).
    func needsCertificateRecheck(_ host: String, profile: BrowserProfileID) -> Bool {
        certificateRechecks[profile]?.contains(host) == true && !hasCertificateException(host, profile: profile)
    }

    /// `tab`'s page is from a host whose certificate warning the user
    /// turned off. The interstitial itself is not: the user has not
    /// proceeded yet.
    func certificateWarningsTurnedOff(_ tab: WebKitTab) -> Bool {
        guard tab.state.loadError == nil, let host = tab.state.url?.host() else { return false }
        return hasCertificateException(host, profile: tab.profileID)
    }

    /// The page was loaded past its untrusted certificate: the host is
    /// excepted and WebKit's own evaluation failed (a host whose
    /// certificate became valid again is not broken).
    func loadedPastCertificateWarning(_ tab: WebKitTab) -> Bool {
        let activity = tab.pageInfoActivity
        let failed = activity.failedCertificateReason != nil || !activity.failedCertificateChain.isEmpty
        return failed && certificateWarningsTurnedOff(tab)
    }

    /// Forgets the choice for `tab`'s page host and reloads the page, which
    /// shows the warning again.
    func turnOnCertificateWarnings(_ tab: WebKitTab) -> Bool {
        guard certificateWarningsTurnedOff(tab), let host = tab.state.url?.host(),
              forgetCertificateException(host: host, profile: tab.profileID) else { return false }
        tab.reload()
        return true
    }
}
