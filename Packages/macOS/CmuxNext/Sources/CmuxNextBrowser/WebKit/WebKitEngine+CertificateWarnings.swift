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

    /// The navigation action policy of a main-frame load in `tab`: a host
    /// being rechecked has its certificate checked first, and `decide` (the
    /// policy decision) waits for the result, so the page never commits
    /// before it. Untrusted: the load is cancelled and the interstitial
    /// shows.
    func admitMainFrameLoad(_ url: URL, in tab: WebKitTab, decide: @escaping @MainActor (Bool) -> Void) {
        guard url.scheme?.lowercased() == "https", let host = url.host(),
              needsCertificateRecheck(host, profile: tab.profileID) else { return decide(true) }
        let profile = tab.profileID, tabID = tab.id
        let probe = certificateProbe
        let admission = (certificateAdmissions[tabID] ?? 0) + 1
        certificateAdmissions[tabID] = admission
        Task { [weak self, weak tab] in
            let result = await probe(url)
            let newest = self?.certificateAdmissions[tabID] == admission
            if newest { self?.certificateAdmissions[tabID] = nil }
            guard let self, let tab, !tab.isClosed else { return decide(false) }
            switch result {
            case .trusted:
                certificateRechecks[profile]?.remove(host)
                decide(true)
            case .unknown:
                // WebKit's own TLS check still runs on a new connection.
                decide(true)
            case .untrusted(let chain, let reason):
                decide(false)
                // A newer load of this tab replaced this one: no interstitial for it.
                guard newest else { return }
                showCertificateInterstitial(url, chain: chain, reason: reason, in: tab)
            }
        }
    }

    /// The interstitial for `url` in `tab`, without a WebKit navigation (a
    /// synthetic failed load with NSURLErrorServerCertificateUntrusted).
    private func showCertificateInterstitial(_ url: URL, chain: [Data], reason: String?, in tab: WebKitTab) {
        tab.pageInfoActivity.recordCertificateFailure(chain: chain, reason: reason)
        let id = tab.allocateNavigationID()
        tab.apply(.started(id, url: url))
        tab.apply(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                                               message: reason ?? "", failingURL: url)))
    }

    /// The user proceeded past `host`'s certificate in `profile` (the
    /// interstitial's Proceed).
    func allowCertificateException(host: String, profile: BrowserProfileID) {
        certificateExceptions[profile, default: []].insert(host)
        certificateRechecks[profile]?.remove(host)
    }

    /// The next page of `host` in `profile` must have its server trust
    /// verified again before it loads (`admitMainFrameLoad`): warnings were
    /// turned on again, and WebKit may reuse a kept-alive connection that
    /// was trusted by the old exception (no new TLS challenge, so the page
    /// would load without the warning). WebKit has no public call to close
    /// those connections.
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

    /// The store has a Proceed for `tab`'s page host in its profile (the
    /// revoke action is enabled only then).
    func knowsCertificateBypass(_ tab: WebKitTab) -> Bool {
        guard let host = tab.state.url?.host() else { return false }
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
        guard let host = tab.state.url?.host(), forgetCertificateException(host: host, profile: tab.profileID) else { return false }
        tab.reload()
        return true
    }
}
