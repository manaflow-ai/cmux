public import Foundation

/// Chromium side of Page Info, through CEF's own API over the same stores
/// Chromium's Page Info uses: content settings of the tab's `CefRequestContext`
/// (Chromium's HostContentSettingsMap enforces every kind natively), its
/// `CefCookieManager`, and the visible entry's `CefSSLStatus`. DevTools is
/// used only where CEF has no API: the page's resource tree (which sites
/// the page touched) and `Storage.clearDataForOrigin`.
extension CEFTab: PageInfoProviding {
    public var pageInfoSettings: SiteSettingsRegistry { .shared }

    public var supportedSitePermissions: Set<SitePermissionKind> { Set(SitePermissionKind.allCases) }

    public var pageInfoInUse: Set<SitePermissionKind> { [] }

    public func pageInfoCertificateChain() async -> [Data] {
        guard let browserID else { return [] }
        if let status = runtime.sslStatus(browserID), !status.chain.isEmpty { return status.chain }
        guard let url = state.url, let origin = PageInfoSite.origin(of: url),
              let json = try? await runtime.devTools(browserID, method: "Network.getCertificate", params: ["origin": origin])
        else { return [] }
        return CEFPageInfoParsing.certificates(json)
    }

    public func pageInfoSiteData(pageHost: String?) async -> SiteDataSummary {
        guard let browserID else { return SiteDataSummary() }
        let hosts = await pageHosts()
        let cookies = ((try? await runtime.cookies(browserID)) ?? []).filter { cookie in hosts.contains { cookie.matches(host: $0) } }
        // Chromium allows third-party cookies unless the user blocks them, and
        // then hides the cookies subpage's third-party section.
        return .grouping(cookieDomains: cookies.map(\.domain), pageHost: pageHost, thirdPartyPolicy: .allowed)
    }

    public func pageInfoDeleteSiteData(domains: [String]) async {
        guard let browserID else { return }
        let targets = Set(domains.map(SiteDomain.registrable))
        let cookies = (try? await runtime.cookies(browserID)) ?? []
        var deleted: Set<CEFCookie> = []
        for cookie in cookies where targets.contains(SiteDomain.registrable(cookie.domain)) && deleted.insert(cookie).inserted {
            _ = try? await runtime.deleteCookies(browserID, url: "https://\(cookie.host)/", name: cookie.name)
        }
        // Storage (local, session, IndexedDB, cache, service workers) has no
        // CEF API; DevTools clears it per origin.
        for domain in targets {
            for scheme in ["https", "http"] {
                _ = try? await runtime.devTools(browserID, method: "Storage.clearDataForOrigin",
                                                params: ["origin": "\(scheme)://\(domain)", "storageTypes": "all"])
            }
        }
    }

    /// Chromium's site exceptions for `origin`: kinds whose value differs
    /// from the profile default (what Chromium counts as changed), including
    /// answers the user gave to Chromium's own prompts.
    public func pageInfoLivePermissions(origin: String) async -> [SitePermissionKind: SitePermissionSetting] {
        guard let browserID else { return [:] }
        var result: [SitePermissionKind: SitePermissionSetting] = [:]
        for kind in supportedSitePermissions {
            guard let value = runtime.contentSetting(browserID, url: origin, kind: kind),
                  value != runtime.contentSetting(browserID, url: nil, kind: kind),
                  let setting = value.siteSetting else { continue }
            result[kind] = setting
        }
        return result
    }

    public func pageInfoDidChange(_ kind: SitePermissionKind, to setting: SitePermissionSetting, origin: String) async {
        applyToChromium(kind, setting, origin: origin)
    }

    // MARK: Engine hooks (CEFTab+Events)

    /// A document committed: reset activity and push the shared store's
    /// decisions for its origin into Chromium (decisions made in a WebKit tab
    /// of the same profile included). Chromium persists them, so later loads
    /// of the origin start with them.
    func pageInfoDocumentCommitted(_ url: URL?) {
        let origin = url.flatMap(PageInfoSite.origin(of:))
        pageInfoActivity.documentCommitted(origin: origin)
        syncSecurityFromChromium()
        guard let origin, browserID != nil else { return }
        let store = sitePermissions
        Task { [weak self] in
            await store.whenLoaded()
            guard let self else { return }
            for (kind, setting) in store.decisions[origin] ?? [:] {
                self.applyToChromium(kind, setting, origin: origin)
            }
        }
    }

    /// Refines the scheme-level security with Chromium's SSL status:
    /// certificate errors the user proceeded through and mixed content.
    func syncSecurityFromChromium() {
        guard let browserID, state.url?.scheme == "https", let status = runtime.sslStatus(browserID) else { return }
        let security: BrowserSecurityState = if status.hasCertificateError {
            .broken
        } else if status.hasMixedContent {
            .mixedContent
        } else {
            .secure
        }
        if security != state.security { machine.apply(.securityChanged(security)) }
    }

    /// The default value clears Chromium's exception ("Ask (default)");
    /// others store one.
    private func applyToChromium(_ kind: SitePermissionKind, _ setting: SitePermissionSetting, origin: String) {
        guard let browserID else { return }
        let value: CEFContentSetting = setting == kind.defaultSetting ? .default : CEFContentSetting(setting)
        runtime.setContentSetting(browserID, url: origin, kind: kind, value: value)
    }

    /// Hosts of the page and of every frame and resource it loaded.
    private func pageHosts() async -> [String] {
        var urls: [String] = state.url.map { [$0.absoluteString] } ?? []
        if let browserID, let tree = try? await runtime.devTools(browserID, method: "Page.getResourceTree") {
            urls += CEFPageInfoParsing.resourceOrigins(tree)
        }
        return Array(Set(urls.compactMap { URL(string: $0)?.host() }))
    }
}
