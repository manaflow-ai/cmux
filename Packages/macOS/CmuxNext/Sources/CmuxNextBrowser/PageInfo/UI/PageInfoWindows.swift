import AppKit
import CmuxNextDesign

/// The windows one bubble opens. Each exists at most once per pane and is
/// reused (brought forward) when opened again.
final class PageInfoWindows {
    private var certificate: CertificateViewerWindow?
    private var siteSettings: SiteSettingsWindow?
    private var siteData: SiteDataWindow?
    var ownedWindows: [NSWindow] { [certificate, siteSettings, siteData].compactMap { $0 } }
    /// The shell window the bubble belongs to (`WindowPlacement`).
    var parentWindow: () -> NSWindow? = { nil }

    func showCertificate(_ chain: [PageInfoCertificate], site: PageInfoSite, failure: String?) {
        certificate?.close()
        let window = CertificateViewerWindow(chain: chain, site: site, failure: failure, activeLook: parentWindow()?.backdropActiveLook)
        certificate = window
        present(window)
    }

    func showSiteSettings(origin: String, site: PageInfoSite, store: SitePermissionStore, provider: any PageInfoProviding,
                          send: @escaping (PageInfoCommand) -> Void) {
        if let siteSettings, siteSettings.origin == origin {
            return present(siteSettings)
        }
        siteSettings?.close()
        let window = SiteSettingsWindow(origin: origin, site: site, store: store, provider: provider, send: send,
                                        activeLook: parentWindow()?.backdropActiveLook)
        siteSettings = window
        present(window)
    }

    func showSiteData(site: PageInfoSite, provider: any PageInfoProviding, send: @escaping (PageInfoCommand) -> Void) {
        siteData?.close()
        let window = SiteDataWindow(site: site, send: send, activeLook: parentWindow()?.backdropActiveLook)
        siteData = window
        present(window)
        Task { [weak window] in
            let data = await provider.pageInfoSiteData(pageHost: site.host)
            window?.show(data)
        }
    }

    func siteDataChanged(_ data: SiteDataSummary) {
        siteData?.show(data)
        siteSettings?.show(data)
    }

    func closeAll() {
        ownedWindows.forEach { $0.close() }
        certificate = nil
        siteSettings = nil
        siteData = nil
    }

    private func present(_ window: NSWindow) {
        // The shell window's theme scope (its room).
        let scope = parentWindow()?.themeScope ?? .app
        scope.adopt(window)
        WindowPlacement.present(window, parent: parentWindow())
    }
}

/// Shared window chrome for the page info windows: titled, closable,
/// kind `.pageInfo` (the one surface background), not released on close.
class PageInfoWindow: NSWindow {
    /// The shell window's ``ActiveLookScope`` (its `backdropActiveLook`), for this window's backdrop.
    private let activeLook: ActiveLookScope?

    init(title: String, size: CGSize, activeLook: ActiveLookScope?) {
        self.activeLook = activeLook
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        self.title = title
        isReleasedWhenClosed = false
        minSize = NSSize(width: size.width * 0.8, height: size.height * 0.6)
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
    }

    /// Sets the window's content through the window kit (kind
    /// `.pageInfo`); `PageInfoWindows` adopts the shell window's scope.
    func installContent(_ content: NSView) {
        install(kind: .pageInfo, content: content, scope: themeScope, activeLook: activeLook)
    }

    /// Escape closes.
    override func cancelOperation(_ sender: Any?) { close() }

    static func sectionTitle(_ text: String) -> ThemedLabel {
        PageInfoStyle.label(text, font: PageInfoStyle.headerFont, color: PageInfoStyle.text)
    }

    static func valueLabel(_ text: String, selectable: Bool = true) -> ThemedLabel {
        let label = PageInfoStyle.label(text, font: PageInfoStyle.bodyFont, color: PageInfoStyle.text, wraps: true)
        label.isSelectable = selectable
        return label
    }
}
