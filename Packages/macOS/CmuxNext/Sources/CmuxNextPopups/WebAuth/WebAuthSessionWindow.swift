import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import os

/// One sign-in's window and page. Every end (the callback, the close
/// button, Escape, `window.close()`, the system cancelling) closes it once.
@MainActor
final class WebAuthSessionWindow: NSObject, WebAuthSessionSurface, BrowserTabDelegate {
    let id: UUID
    private let url: URL
    private let callback: WebAuthCallback
    private let ephemeralProfile: BrowserProfileID?
    private weak var broker: WebAuthSessionBroker?
    /// The app's services: the Chromium page and links out.
    private let host: any WebAuthHost
    private let logger: Logger
    private let profiles: OffTheRecordProfiles
    private let signInCallbacks: CEFSignInCallbacks
    private let contextMenus: BrowserContextMenuBuilder
    /// Orders the panel in (`WindowActivation.show` in the app).
    private let present: @MainActor (NSWindow, WindowActivation.Intent) -> Void
    private let onEnd: (UUID) -> Void
    private var page: (any BrowserTab)?
    private var panel: BrowserPopupWindow?
    private var observation: Task<Void, Never>?
    private var ended = false

    init(
        request: any WebAuthSessionRequest,
        broker: WebAuthSessionBroker,
        host: any WebAuthHost,
        logger: Logger,
        profiles: OffTheRecordProfiles,
        signInCallbacks: CEFSignInCallbacks,
        contextMenus: BrowserContextMenuBuilder,
        present: @escaping @MainActor (NSWindow, WindowActivation.Intent) -> Void,
        onEnd: @escaping (UUID) -> Void
    ) {
        id = request.id
        url = request.url
        callback = request.callback
        ephemeralProfile = request.isEphemeral ? profiles.begin() : nil
        self.broker = broker
        self.host = host
        self.logger = logger
        self.profiles = profiles
        self.signInCallbacks = signInCallbacks
        self.contextMenus = contextMenus
        self.present = present
        self.onEnd = onEnd
    }

    func start() {
        let configuration = BrowserTabConfiguration(profile: ephemeralProfile ?? .default)
        let host = host
        Task { [weak self] in
            do {
                let page = try await host.makeSignInPage(configuration)
                guard let self, !self.ended else { return page.close() }
                self.show(page)
            } catch {
                self?.logger.error("sign-in window: no Chromium page: \(String(describing: error), privacy: .public)")
                self?.end()
            }
        }
    }

    private func show(_ page: any BrowserTab) {
        self.page = page
        page.delegate = self
        // The shim stops the callback before it loads; set before the first navigation.
        if callback == .none {
            logger.notice("sign-in window: callback unknown; the page URL check ends the session")
        }
        if let cef = page as? CEFTab {
            signInCallbacks.set(Self.shimCallback(callback), on: cef) { [weak self] url in self?.shimStopped(url) }
        }
        let panel = BrowserPopupWindow(page: page, frame: Self.frame(), readOnlyAddress: true)
        panel.onEscape = { [weak self] in self?.close() }
        panel.onClose = { [weak self] in self?.end() }
        self.panel = panel
        observeNavigation(page)
        page.load(url)
        // `.focus` makes the panel key and activates the app; under
        // no-activate (`WindowPlacement.noActivate`) it only orders it front.
        present(panel, .focus)
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
        guard !ended, broker?.navigated(id, to: url) != true else { return }
        logger.notice("sign-in window: the system did not take a stopped callback")
        // An https page loads after all: the shim stops nothing more (or it
        // would stop this load again), and the page URL check stays. Another
        // app's link from a sign-in page does not open.
        guard url.scheme?.lowercased() == "https", let cef = page as? CEFTab else { return }
        signInCallbacks.set(nil, on: cef, onCallback: nil)
        page?.load(url)
    }

    /// The last line when the shim could not know the callback: the session
    /// ends as soon as the page reaches it.
    private func observeNavigation(_ page: any BrowserTab) {
        observation = Task { [weak self, weak page] in
            guard let page else { return }
            for await url in ObservationStream({ page.state.url }) {
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
        if let ephemeralProfile { profiles.end(ephemeralProfile) }
        broker?.surfaceClosed(id)
        onEnd(id)
    }

    // MARK: BrowserTabDelegate

    func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
        switch intent {
        case .close, .unhandledEscape:
            close()
        case .openURL(let url, _):
            // The callback in a new tab still ends this session; any other
            // link out of the sign-in (terms, help) opens as a normal tab.
            guard broker?.navigated(id, to: url) != true else { return }
            host.openSignInLink(url)
        case .adoptTab(let child, _), .openPopup(let child, _):
            // A sign-in page's own popups have no tab to belong to.
            child.close()
        case .contextMenu(let request):
            contextMenus.present(request, in: tab.contentView, leading: [])
        default:
            break
        }
    }
}
