import AppKit
public import Foundation
import Security
public import WebKit

/// WebKit side of Page Info: `serverTrust` certificates, the profile's
/// `WKWebsiteDataStore`, media capture decisions from the shared store, and
/// per-navigation JavaScript (`WKWebpagePreferences.allowsContentJavaScript`).
extension WebKitTab: PageInfoProviding {
    public var pageInfoSettings: SiteSettingsRegistry { engine?.siteSettings ?? .shared }

    /// WebKit has public API for these only: camera and microphone through
    /// `WKUIDelegate`, JavaScript through `WKWebpagePreferences`. Location,
    /// notifications, pop-ups, sound and the rest have no per-site hook.
    public var supportedSitePermissions: Set<SitePermissionKind> { [.camera, .microphone, .javascript] }

    public var pageInfoInUse: Set<SitePermissionKind> {
        var kinds: Set<SitePermissionKind> = []
        if webView.cameraCaptureState == .active { kinds.insert(.camera) }
        if webView.microphoneCaptureState == .active { kinds.insert(.microphone) }
        return kinds
    }

    public func pageInfoCertificateChain() async -> [Data] {
        if let trust = webView.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            return chain.map { SecCertificateCopyData($0) as Data }
        }
        return pageInfoActivity.failedCertificateChain
    }

    public func pageInfoSiteData(pageHost: String?) async -> SiteDataSummary {
        let store = webView.configuration.websiteDataStore
        let cookies = await store.httpCookieStore.allCookies()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let pageSites = await pageResourceSites(pageHost: pageHost)
        let relevant = cookies.map(\.domain).filter { pageSites.contains(SiteDomain.registrable($0)) }
        let other = records.map(\.displayName).filter { pageSites.contains(SiteDomain.registrable($0)) && !$0.isEmpty }
        // WKWebView blocks third-party cookies (Intelligent Tracking
        // Prevention); there is no per-site exception API.
        return .grouping(cookieDomains: relevant, otherDataDomains: other, pageHost: pageHost, thirdPartyPolicy: .blocked)
    }

    public func pageInfoDeleteSiteData(domains: [String]) async {
        let targets = Set(domains.map(SiteDomain.registrable))
        let store = webView.configuration.websiteDataStore
        for cookie in await store.httpCookieStore.allCookies() where targets.contains(SiteDomain.registrable(cookie.domain)) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { targets.contains(SiteDomain.registrable($0.displayName)) }
        await store.removeData(ofTypes: types, for: records)
    }

    public func pageInfoLivePermissions(origin: String) async -> [SitePermissionKind: SitePermissionSetting] { [:] }

    public func pageInfoDidChange(_ kind: SitePermissionKind, to setting: SitePermissionSetting, origin: String) async {
        guard setting == .block else { return }
        // Blocking stops a capture in progress at once, as Chrome does.
        switch kind {
        case .camera: await webView.setCameraCaptureState(.none)
        case .microphone: await webView.setMicrophoneCaptureState(.none)
        default: break
        }
    }

    /// Sites (registrable domains) of the page and every resource it loaded,
    /// from the Resource Timing API in an isolated world.
    private func pageResourceSites(pageHost: String?) async -> Set<String> {
        var sites: Set<String> = []
        if let pageHost { sites.insert(SiteDomain.registrable(pageHost)) }
        let script = "[location.hostname].concat(performance.getEntriesByType('resource').map(e => { try { return new URL(e.name).hostname } catch (_) { return '' } }))"
        if case .array(let values) = try? await evaluate(script, world: .isolated) {
            for case .string(let host) in values where !host.isEmpty { sites.insert(SiteDomain.registrable(host)) }
        }
        return sites
    }

    // MARK: Engine hooks (WebKitTab+Delegates)

    /// Answers a media capture request from the stored decisions, asking
    /// only when the site has none, and stores the answer.
    func decideMediaCapture(_ kind: BrowserPermissionKind, origin: String, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let kinds: Set<SitePermissionKind> = switch kind {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        }
        pageInfoActivity.recordRequest(kinds)
        let store = sitePermissions
        Task { [weak self] in
            await store.whenLoaded()
            let settings = kinds.map { store.setting($0, for: origin) }
            if settings.contains(.block) { return decisionHandler(.deny) }
            if settings.allSatisfy({ $0 == .allow }) { return decisionHandler(.grant) }
            guard let self else { return decisionHandler(.deny) }
            self.enqueuePrompt(.permission(kind), origin: origin) { response in
                switch response {
                case .allow: kinds.forEach { store.set(.allow, $0, for: origin) }
                case .deny: kinds.forEach { store.set(.block, $0, for: origin) }
                default: break
                }
                decisionHandler(response == .allow || response == .allowOnce ? .grant : .deny)
            }
        }
    }

    /// JavaScript on or off for the document a navigation loads.
    func applySiteSettings(to preferences: WKWebpagePreferences, for action: WKNavigationAction) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let topOrigin = isMainFrame ? action.request.url.flatMap(PageInfoSite.origin(of:)) : webView.url.flatMap(PageInfoSite.origin(of:))
        let frameOrigin = action.request.url.flatMap(PageInfoSite.origin(of:))
        if let allowed = Self.allowsJavaScript(isMainFrame: isMainFrame, frameOrigin: frameOrigin, topOrigin: topOrigin,
                                               store: sitePermissions) {
            preferences.allowsContentJavaScript = allowed
        }
    }

    /// Whether a document may run JavaScript under the per-site setting;
    /// nil leaves WebKit's default. A frame runs no script when its own
    /// origin is blocked or when the top-level site is (Chrome keys the
    /// setting on the top-level site; WebKit applies preferences per frame
    /// navigation, so each frame is decided here).
    static func allowsJavaScript(isMainFrame: Bool, frameOrigin: String?, topOrigin: String?,
                                 store: SitePermissionStore) -> Bool? {
        let origins = [frameOrigin, isMainFrame ? nil : topOrigin].compactMap { $0 }
        guard !origins.isEmpty else { return nil }
        return !origins.contains { store.setting(.javascript, for: $0) == .block }
    }

    /// Records the server's certificate when WebKit's own evaluation fails,
    /// so Page Info can show "Certificate is not valid" on the error page.
    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            // Evaluation can fetch intermediates or revocation data: never
            // on the main thread (architecture.md 5a).
            let box = ServerTrustBox(trust: trust)
            Task.detached { [weak self] in
                let result = box.evaluate()
                await MainActor.run {
                    guard let activity = self?.pageInfoActivity else { return }
                    if let failure = result {
                        activity.recordCertificateFailure(chain: failure.chain, reason: failure.reason)
                    } else {
                        activity.clearCertificateFailure()
                    }
                }
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// A `SecTrust` handed to a background evaluation. SecTrust is thread-safe
/// for evaluation; it is only not annotated `Sendable`.
nonisolated struct ServerTrustBox: @unchecked Sendable {
    let trust: SecTrust

    /// nil when the trust evaluates, else the chain and the failure reason.
    func evaluate() -> (chain: [Data], reason: String?)? {
        var error: CFError?
        guard !SecTrustEvaluateWithError(trust, &error) else { return nil }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).map { SecCertificateCopyData($0) as Data }
        return (chain, error.map { CFErrorCopyDescription($0) as String })
    }
}
