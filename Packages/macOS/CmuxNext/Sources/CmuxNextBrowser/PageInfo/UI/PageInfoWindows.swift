import AppKit
import CmuxNextDesign
import CmuxNextPages
import UniformTypeIdentifiers

/// The windows one bubble opens: the certificate viewer, site settings and on-device site data.
/// Each exists at most once per pane and is reused (brought forward) when opened again. Each is a
/// native window (placement, the shell window's theme scope, Escape) whose content is a React page
/// (webviews/src/pages/certificate, site-settings, site-data) drawn from `PageInfoWindowWire`.
final class PageInfoWindows {
    /// Makes a window's React page; tests pass their own.
    var makeWebContent: @MainActor (BrowserChromeWebPage) -> (any BrowserChromeWebContent)? = { BrowserChromeWebHost($0) }
    private var certificate: PageInfoWebWindow?
    private var siteSettings: SiteSettingsSource?
    private var siteData: PageInfoWebWindow?
    var ownedWindows: [NSWindow] { [certificate, siteSettings?.window, siteData].compactMap { $0 } }
    /// The shell window the bubble belongs to (`WindowPlacement`).
    var parentWindow: () -> NSWindow? = { nil }

    func showCertificate(_ chain: [PageInfoCertificate], site: PageInfoSite, failure: String?) {
        certificate?.close()
        let name = chain.first?.subject.commonName ?? site.host ?? site.displayName
        guard let window = makeWindow(.certificate, title: PageInfoStrings.viewerTitle(name), width: 520) else { return }
        window.setAccessibilityIdentifier("cmux.pageInfo.certificateViewer")
        window.onCommand = { [weak window] command in
            switch command {
            case .exportCertificate(let index) where chain.indices.contains(index):
                Self.export(Array(chain[index...]), from: window)
            case .close: window?.close()
            default: break
            }
        }
        window.onClose = { [weak self, weak window] in if self?.certificate === window { self?.certificate = nil } }
        certificate = window
        window.push(PageInfoWindowWire.certificate(chain: chain, failure: failure))
    }

    func showSiteSettings(origin: String, site: PageInfoSite, store: SitePermissionStore, provider: any PageInfoProviding,
                          send: @escaping (PageInfoCommand) -> Void) {
        if let siteSettings, siteSettings.origin == origin {
            // One still loading opens on its own when its page reports its height.
            if siteSettings.window.isReady { present(siteSettings.window) }
            return
        }
        siteSettings?.window.close()
        guard let window = makeWindow(.siteSettings, title: PageInfoStrings.siteSettingsTitle(site.displayName), width: 460) else { return }
        window.setAccessibilityIdentifier("cmux.pageInfo.siteSettings")
        let source = SiteSettingsSource(window: window, origin: origin, site: site, store: store, provider: provider, send: send)
        window.onClose = { [weak self, weak source] in
            source?.stop()
            if self?.siteSettings === source { self?.siteSettings = nil }
        }
        siteSettings = source
        source.start()
    }

    func showSiteData(site: PageInfoSite, provider: any PageInfoProviding, send: @escaping (PageInfoCommand) -> Void) {
        siteData?.close()
        guard let window = makeWindow(.siteData, title: PageInfoStrings.siteDataTitle, width: 440) else { return }
        window.setAccessibilityIdentifier("cmux.pageInfo.siteData")
        window.onCommand = { [weak window] command in
            switch command {
            case .deleteSiteData(let domain?): send(.deleteSiteData(domain: domain))
            case .close: window?.close()
            default: break
            }
        }
        window.onClose = { [weak self, weak window] in if self?.siteData === window { self?.siteData = nil } }
        siteData = window
        window.push(PageInfoWindowWire.siteData(nil))
        Task { [weak window] in
            let data = await provider.pageInfoSiteData(pageHost: site.host)
            window?.push(PageInfoWindowWire.siteData(data))
        }
    }

    func siteDataChanged(_ data: SiteDataSummary) {
        siteData?.push(PageInfoWindowWire.siteData(data))
        siteSettings?.usage = data
    }

    func closeAll() {
        ownedWindows.forEach { $0.close() }
        certificate = nil
        siteSettings = nil
        siteData = nil
    }

    /// A window over a new page; it opens once the page reported its height.
    private func makeWindow(_ page: BrowserChromeWebPage, title: String, width: CGFloat) -> PageInfoWebWindow? {
        guard let content = makeWebContent(page) else { return nil }
        let window = PageInfoWebWindow(content: content, title: title, width: width, activeLook: parentWindow()?.backdropActiveLook)
        window.onReady = { [weak self, weak window] in
            guard let self, let window else { return }
            self.present(window)
        }
        return window
    }

    private func present(_ window: NSWindow) {
        // The shell window's theme scope (its room).
        let scope = parentWindow()?.themeScope ?? .app
        scope.adopt(window)
        WindowPlacement.present(window, parent: parentWindow())
    }

    /// Writes the chain as PEM (the viewer's Export).
    static func export(_ chain: [PageInfoCertificate], from window: NSWindow?) {
        guard let first = chain.first else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (first.subject.commonName ?? "certificate").replacingOccurrences(of: "*", with: "_") + ".pem"
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]
        let text = chain.map(\.pem).joined()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// The site settings window's state and commands for one origin (like `chrome://settings/
/// content/siteDetails`): usage with Delete data, every permission this engine enforces with its
/// choices, and Reset permissions. Pushes the page a new state whenever the store changes.
private final class SiteSettingsSource {
    let window: PageInfoWebWindow
    let origin: String
    private let site: PageInfoSite
    private let store: SitePermissionStore
    private let provider: any PageInfoProviding
    private let send: (PageInfoCommand) -> Void
    private var observation: ObservationLoop?
    var usage: SiteDataSummary? { didSet { render() } }

    init(window: PageInfoWebWindow, origin: String, site: PageInfoSite, store: SitePermissionStore,
         provider: any PageInfoProviding, send: @escaping (PageInfoCommand) -> Void) {
        self.window = window
        self.origin = origin
        self.site = site
        self.store = store
        self.provider = provider
        self.send = send
    }

    func start() {
        window.onCommand = { [weak self] command in self?.perform(command) }
        observation = ObservationLoop { [weak self] in self?.render() }
        Task { [weak self, provider, origin] in
            let data = await provider.pageInfoSiteData(pageHost: URL(string: origin)?.host())
            self?.usage = data
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    private func render() {
        window.push(PageInfoWindowWire.siteSettings(site: site, origin: origin, supported: provider.supportedSitePermissions,
                                                    decisions: store.decisions[origin] ?? [:], usage: usage))
    }

    /// The bubble's page is still on this origin: go through the registry action; otherwise edit
    /// this origin's store entry directly.
    private var isCurrentOrigin: Bool {
        (provider as? any BrowserTab)?.state.url.flatMap(PageInfoSite.origin(of:)) == origin
    }

    private func perform(_ command: PageInfoWindowCommand) {
        switch command {
        case .setPermission(let kind, let setting):
            guard provider.supportedSitePermissions.contains(kind) else { return }
            if isCurrentOrigin { return send(.setPermission(kind, setting)) }
            store.set(setting, kind, for: origin)
            Task { [provider, origin] in await provider.pageInfoDidChange(kind, to: setting, origin: origin) }
        case .resetPermissions:
            if isCurrentOrigin { return send(.resetPermissions) }
            // The engine keeps its own decisions (Chromium persists content settings): reset each
            // one the store or the engine had, not only the store.
            let stored = store.changedKinds(for: origin)
            store.reset(origin: origin)
            Task { [provider, origin] in
                let live = await provider.pageInfoLivePermissions(origin: origin)
                for kind in stored.union(live.keys) {
                    await provider.pageInfoDidChange(kind, to: kind.defaultSetting, origin: origin)
                }
            }
        case .deleteSiteData:
            guard let host = URL(string: origin)?.host() else { return }
            send(.deleteSiteData(domain: SiteDomain.registrable(host)))
        case .close:
            window.close()
        case .exportCertificate:
            break
        }
    }
}
