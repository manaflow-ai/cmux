import AppKit
import CmuxNextBrowser
import CmuxNextDesign

/// Opens each sign-in in its own panel with a Chromium page, the same
/// panel a page's sign-in popup uses (title and origin, close button,
/// Escape). It is not a daemon tab: nothing records, restores or lists it.
/// A normal session uses the default browser profile, so a person already
/// signed in stays signed in; an ephemeral one gets an off-the-record
/// profile that ends with the panel.
@MainActor
final class WebAuthSessionWindows: WebAuthSessionOpening {
    // crash-allow: AppServices owns this opener (through the broker) for the app's whole life.
    private unowned let services: AppServices
    private(set) var windows: [UUID: WebAuthSessionWindow] = [:]

    init(services: AppServices) {
        self.services = services
    }

    func open(_ request: any WebAuthSessionRequest, broker: WebAuthSessionBroker) -> (any WebAuthSessionSurface)? {
        let window = WebAuthSessionWindow(request: request, broker: broker, services: services) { [weak self] id in
            self?.windows[id] = nil
        }
        windows[request.id] = window
        window.start()
        return window
    }
}

/// One sign-in's panel and page. Every end (the callback, the close
/// button, Escape, `window.close()`, the system cancelling) closes it once.
@MainActor
final class WebAuthSessionWindow: NSObject, WebAuthSessionSurface, BrowserTabDelegate {
    let id: UUID
    private let url: URL
    private let callback: WebAuthCallback
    private let ephemeralProfile: BrowserProfileID?
    private weak var broker: WebAuthSessionBroker?
    // crash-allow: AppServices outlives every sign-in window.
    private unowned let services: AppServices
    private let onEnd: (UUID) -> Void
    private var page: (any BrowserTab)?
    private var panel: BrowserPopupPanel?
    private var observation: Task<Void, Never>?
    private var ended = false

    init(request: any WebAuthSessionRequest, broker: WebAuthSessionBroker, services: AppServices, onEnd: @escaping (UUID) -> Void) {
        id = request.id
        url = request.url
        callback = request.callback
        ephemeralProfile = request.isEphemeral ? OffTheRecordProfiles.shared.begin() : nil
        self.broker = broker
        self.services = services
        self.onEnd = onEnd
    }

    func start() {
        let configuration = BrowserTabConfiguration(profile: ephemeralProfile ?? .default)
        let cef = services.cache.cef
        Task { [weak self] in
            do {
                let page = try await cef.makeTab(configuration)
                guard let self, !self.ended else { return page.close() }
                self.show(page)
            } catch {
                self?.services.daemon.logger.error("sign-in window: no Chromium page: \(String(describing: error), privacy: .public)")
                self?.end()
            }
        }
    }

    private func show(_ page: any BrowserTab) {
        self.page = page
        page.delegate = self
        // The shim stops the callback before it loads; set before the first navigation.
        if let cef = page as? CEFTab {
            cef.setSignInCallback(Self.shimCallback(callback)) { [weak self] url in self?.shimStopped(url) }
        }
        let panel = BrowserPopupPanel(page: page, frame: Self.frame())
        panel.onEscape = { [weak self] in self?.close() }
        panel.onClose = { [weak self] in self?.end() }
        self.panel = panel
        observeNavigation(page)
        page.load(url)
        WindowActivation.show(panel, services.environment.noActivate ? .raise : .focus)
        if !services.environment.noActivate { NSApp.activate() }
        if panel.isKeyWindow { page.setFocused(true) }
    }

    static func shimCallback(_ callback: WebAuthCallback) -> CEFSignInCallback? {
        switch callback {
        case .customScheme(let scheme): CEFSignInCallback(scheme: scheme)
        case .https(let host, let path): CEFSignInCallback(host: host, path: path)
        case .none: nil
        }
    }

    /// A centered panel the size of a sign-in page.
    static func frame() -> CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size = CGSize(width: min(520, visible.width - 40), height: min(700, visible.height - 40))
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The shim stopped a navigation that looked like the callback. The
    /// system's matcher decides; a URL it does not take goes where it would
    /// have gone (a page loads, another app's link opens in that app).
    private func shimStopped(_ url: URL) {
        guard broker?.navigated(id, to: url) != true else { return }
        if url.scheme?.lowercased() == "https" { page?.load(url) } else { NSWorkspace.shared.open(url) }
    }

    /// The last line when the shim could not know the callback: the session
    /// ends as soon as the page reaches it.
    private func observeNavigation(_ page: any BrowserTab) {
        observation = Task { [weak self, weak page] in
            guard let page else { return }
            for await url in Observations({ page.state.url }) {
                guard let self, let url else { continue }
                if self.broker?.navigated(self.id, to: url) == true { page.stop() }
            }
        }
    }

    // MARK: WebAuthSessionSurface

    func close() {
        if let panel { panel.close() } else { end() }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        observation?.cancel()
        observation = nil
        panel = nil
        page?.close()
        page = nil
        if let ephemeralProfile { OffTheRecordProfiles.shared.end(ephemeralProfile) }
        broker?.surfaceClosed(id)
        onEnd(id)
    }

    // MARK: BrowserTabDelegate

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        switch intent {
        case .close, .unhandledEscape:
            close()
        case .openURL(let url, _):
            // A link out of the sign-in (terms, help) opens as a normal tab.
            services.externalOpen.openWebLink(url)
        case .adoptTab(let child, _), .openPopup(let child, _):
            // A sign-in page's own popups have no tab to belong to.
            child.close()
        case .contextMenu(let request):
            BrowserContextMenuBuilder.shared.present(request, in: tab.contentView, leading: [])
        default:
            break
        }
    }
}
