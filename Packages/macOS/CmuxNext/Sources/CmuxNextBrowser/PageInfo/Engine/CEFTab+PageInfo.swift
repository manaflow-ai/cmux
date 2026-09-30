public import Foundation

/// Chromium side of Page Info, over the in-process DevTools protocol:
/// `Network.getCertificate`, `Page.getResourceTree` + `Network.getCookies`,
/// `Storage.clearDataForOrigin`, `navigator.permissions` for Chromium's own
/// content settings, and `Browser.setPermission` so the shared store wins
/// over Chromium's remembered prompt answers.
extension CEFTab: PageInfoProviding {
    public var pageInfoSettings: SiteSettingsRegistry { .shared }

    /// Permissions DevTools can set per origin, plus JavaScript
    /// (`Emulation.setScriptExecutionDisabled` per document). Pop-ups, sound,
    /// images, downloads and device choosers need fork API (not yet).
    public var supportedSitePermissions: Set<SitePermissionKind> {
        [.location, .camera, .microphone, .notifications, .javascript, .midi, .clipboard]
    }

    public var pageInfoInUse: Set<SitePermissionKind> { [] }

    public func pageInfoCertificateChain() async -> [Data] {
        guard let browserID, let url = state.url, let origin = PageInfoSite.origin(of: url) else { return [] }
        guard let json = try? await runtime.devTools(browserID, method: "Network.getCertificate", params: ["origin": origin]) else { return [] }
        return CEFPageInfoParsing.certificates(json)
    }

    public func pageInfoSiteData(pageHost: String?) async -> SiteDataSummary {
        guard let browserID else { return SiteDataSummary() }
        var urls: [String] = state.url.map { [$0.absoluteString] } ?? []
        if let tree = try? await runtime.devTools(browserID, method: "Page.getResourceTree") {
            urls += CEFPageInfoParsing.resourceOrigins(tree)
        }
        let cookies = (try? await runtime.devTools(browserID, method: "Network.getCookies", params: ["urls": urls]))
            .map(CEFPageInfoParsing.cookies) ?? []
        // Chrome allows third-party cookies unless the user blocks them, and
        // then hides the cookies subpage's third-party section.
        return .grouping(cookieDomains: cookies.map(\.domain), pageHost: pageHost, thirdPartyPolicy: .allowed)
    }

    public func pageInfoDeleteSiteData(domains: [String]) async {
        guard let browserID else { return }
        let targets = Set(domains.map(SiteDomain.registrable))
        var urls: [String] = state.url.map { [$0.absoluteString] } ?? []
        if let tree = try? await runtime.devTools(browserID, method: "Page.getResourceTree") {
            urls += CEFPageInfoParsing.resourceOrigins(tree)
        }
        let cookies = (try? await runtime.devTools(browserID, method: "Network.getCookies", params: ["urls": urls]))
            .map(CEFPageInfoParsing.cookies) ?? []
        for cookie in cookies where targets.contains(SiteDomain.registrable(cookie.domain)) {
            _ = try? await runtime.devTools(browserID, method: "Network.deleteCookies",
                                            params: ["name": cookie.name, "domain": cookie.domain, "path": cookie.path])
        }
        for domain in targets {
            for scheme in ["https", "http"] {
                _ = try? await runtime.devTools(browserID, method: "Storage.clearDataForOrigin",
                                                params: ["origin": "\(scheme)://\(domain)", "storageTypes": "all"])
            }
        }
    }

    public func pageInfoLivePermissions(origin: String) async -> [SitePermissionKind: SitePermissionSetting] {
        guard state.url.flatMap(PageInfoSite.origin(of:)) == origin else { return [:] }
        let kinds = supportedSitePermissions.compactMap { kind in WebPermissionName.name(for: kind).map { (kind, $0) } }
        let script = CEFPageInfoParsing.permissionQueryScript(names: kinds.map(\.1))
        guard case .array(let values) = try? await evaluate(script, world: .isolated) else { return [:] }
        var result: [SitePermissionKind: SitePermissionSetting] = [:]
        for (index, (kind, _)) in kinds.enumerated() where values.indices.contains(index) {
            if case .string(let state) = values[index], let setting = WebPermissionName.setting(forState: state) { result[kind] = setting }
        }
        return result
    }

    public func pageInfoDidChange(_ kind: SitePermissionKind, to setting: SitePermissionSetting, origin: String) async {
        await applyToChromium(kind, setting, origin: origin)
    }

    // MARK: Engine hooks (CEFTab+Events)

    /// A document committed: reset activity and push the stored decisions
    /// for its origin into Chromium before the page can ask.
    func pageInfoDocumentCommitted(_ url: URL?) {
        let origin = url.flatMap(PageInfoSite.origin(of:))
        pageInfoActivity.documentCommitted(origin: origin)
        guard let origin, browserID != nil else { return }
        let store = sitePermissions
        Task { [weak self] in
            await store.whenLoaded()
            guard let self else { return }
            let decisions = store.decisions[origin] ?? [:]
            await self.setScriptExecution(disabled: decisions[.javascript] == .block)
            for (kind, setting) in decisions where kind != .javascript {
                await self.applyToChromium(kind, setting, origin: origin)
            }
        }
    }

    private func applyToChromium(_ kind: SitePermissionKind, _ setting: SitePermissionSetting, origin: String) async {
        guard let browserID else { return }
        if kind == .javascript {
            await setScriptExecution(disabled: setting == .block)
            return
        }
        guard let name = WebPermissionName.name(for: kind) else { return }
        var params: [String: Any] = ["permission": ["name": name], "setting": WebPermissionName.state(for: setting), "origin": origin]
        // Overrides are per browser context: name this tab's profile.
        if let info = try? await runtime.devTools(browserID, method: "Target.getTargetInfo"),
           let context = CEFPageInfoParsing.browserContextID(info) {
            params["browserContextId"] = context
        }
        if (try? await runtime.devTools(browserID, method: "Browser.setPermission", params: params)) == nil {
            params["browserContextId"] = nil
            _ = try? await runtime.devTools(browserID, method: "Browser.setPermission", params: params)
        }
    }

    private func setScriptExecution(disabled: Bool) async {
        guard let browserID else { return }
        _ = try? await runtime.devTools(browserID, method: "Emulation.setScriptExecutionDisabled", params: ["value": disabled])
    }
}
