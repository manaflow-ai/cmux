import AppKit
import CmuxNextDesign

extension PageInfoController {
    /// Commands that change or open site state.
    func performSiteCommand(_ command: PageInfoCommand) {
        guard let tab else { return }
        let site = PageInfoSite(state: tab.state)
        switch command {
        case .setPermission(let kind, let setting):
            guard let origin = site.origin, let store, let provider else { return }
            store.set(setting, kind, for: origin)
            provider.pageInfoActivity.recordChange(kind)
            model.needsReload = true
            Task { await provider.pageInfoDidChange(kind, to: setting, origin: origin) }
            refreshPermissions()
        case .resetPermissions:
            guard let origin = site.origin, let store, let provider else { return }
            let changed = Set(model.permissions.filter { !$0.isDefault }.map(\.kind))
            store.reset(origin: origin)
            provider.pageInfoActivity.recordChanges(changed)
            model.needsReload = !changed.isEmpty || model.needsReload
            // Chromium remembers its own prompt answers: set those back too.
            Task { for kind in changed { await provider.pageInfoDidChange(kind, to: kind.defaultSetting, origin: origin) } }
            refreshPermissions()
        case .showCertificate:
            showCertificate(site: site)
        case .siteSettings:
            guard let origin = site.origin, let store, let provider else { return }
            close()
            windows.showSiteSettings(origin: origin, site: site, store: store, provider: provider, send: { [weak self] in self?.send($0) })
        case .manageSiteData:
            guard let provider else { return }
            close()
            windows.showSiteData(site: site, provider: provider, send: { [weak self] in self?.send($0) })
        case .deleteSiteData(let domain):
            guard let provider else { return }
            let host = site.host
            Task { [weak self] in
                let targets: [String]
                if let domain {
                    targets = [domain]
                } else {
                    targets = await provider.pageInfoSiteData(pageHost: host).entries.map(\.domain)
                }
                await provider.pageInfoDeleteSiteData(domains: targets + (host.map { [$0] } ?? []))
                self?.reloadSiteData()
            }
        case .aboutThisPage:
            guard let url = model.aboutThisPageURL ?? PageInfoModel.aboutURL(for: site) else { return }
            close()
            tab.delegate?.browserTab(tab, didRequest: .openURL(url, .foregroundTab))
        case .show, .close, .reload, .reenableCertificateWarnings:
            break
        }
    }

    /// Site settings of `origin` (any site of this tab's profile, such as
    /// one whose automatic downloads were blocked), from outside the bubble.
    public func showSiteSettings(origin: String) {
        guard let store, let provider, let url = URL(string: origin) else { return }
        close()
        let site = PageInfoSite(url: url, security: url.scheme == "https" ? .secure : .insecure)
        windows.showSiteSettings(origin: origin, site: site, store: store, provider: provider, send: { [weak self] in self?.send($0) })
    }

    private func showCertificate(site: PageInfoSite) {
        guard let provider else { return }
        close()
        let failure = provider.pageInfoActivity.failedCertificateReason
        Task { [weak self] in
            let chain = await provider.pageInfoCertificateChain().compactMap { try? PageInfoCertificate(der: $0) }
            self?.windows.showCertificate(chain, site: site, failure: failure)
        }
    }

    // MARK: Live data

    /// Keeps the rows current while the bubble is open, and closes it when
    /// the page navigates.
    func startObserving() {
        observation?.cancel()
        observation = ObservationLoop { [weak self] in
            guard let self, let tab = self.tab else { return }
            if tab.state.url != self.openedURL {
                Task { @MainActor [weak self] in self?.close() }
                return
            }
            self.refreshPermissions()
        }
    }

    func refreshPermissions() {
        if let tab {
            let site = PageInfoSite(state: tab.state)
            if site != model.site { model.site = site }
        }
        guard let provider, let store, let origin = model.site.origin else {
            if !model.permissions.isEmpty { model.permissions = [] }
            return
        }
        let activity = provider.pageInfoActivity
        let rows = PageInfoPermissionList.rows(
            supported: provider.supportedSitePermissions,
            decisions: store.decisions[origin] ?? [:],
            live: livePermissions,
            requested: activity.requested,
            inUse: provider.pageInfoInUse.union(activity.inUse),
            changedSinceLoad: activity.changedSinceLoad
        )
        model.supported = provider.supportedSitePermissions
        model.certificateFailure = activity.failedCertificateReason
        if rows != model.permissions {
            model.permissions = rows
            if isShown { render() }
        }
    }

    /// Certificates, site data and the engine's own permission values load
    /// off the click; the bubble renders as each arrives.
    func loadAsyncData() {
        loadTask?.cancel()
        guard let provider else { return }
        let origin = model.site.origin
        let host = model.site.host
        livePermissions = [:]
        loadTask = Task { [weak self] in
            if let origin {
                let live = await provider.pageInfoLivePermissions(origin: origin)
                guard !Task.isCancelled, let self else { return }
                self.livePermissions = live
                self.refreshPermissions()
            }
            let chain = await provider.pageInfoCertificateChain()
            guard !Task.isCancelled, let self else { return }
            self.model.certificates = chain.compactMap { try? PageInfoCertificate(der: $0) }
            if self.isShown, self.model.page == .security { self.render() }
            let data = await provider.pageInfoSiteData(pageHost: host)
            guard !Task.isCancelled else { return }
            self.model.siteData = data
            if self.isShown, self.model.page == .cookies { self.render() }
        }
    }

    func reloadSiteData() {
        guard let provider else { return }
        let host = model.site.host
        Task { [weak self] in
            let data = await provider.pageInfoSiteData(pageHost: host)
            self?.model.siteData = data
            self?.windows.siteDataChanged(data)
            if self?.isShown == true, self?.model.page == .cookies { self?.render() }
        }
    }
}

extension PageInfoModel {
    static func aboutURL(for site: PageInfoSite) -> URL? {
        let model = PageInfoModel()
        model.site = site
        return model.aboutThisPageURL
    }
}
