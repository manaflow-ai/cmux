import AppKit
import WebKit

/// Link clicks of a WebKit tab. Modified clicks follow the engine's
/// `BrowserLinkClickMapping` (Chrome's defaults: Cmd-click and middle click
/// open a background tab, Shift-Cmd-click a foreground tab, Shift-click a
/// new window, Option-click downloads). The link menu is the host's
/// (`WebKitContextHit`, `BrowserHitMenu` in the App).
extension WebKitTab {
    typealias LinkClick = WebKitLinkClick

    static func linkClick(flags: NSEvent.ModifierFlags, button: Int, mapping: BrowserLinkClickMapping = .chrome) -> LinkClick {
        WebKitLinkClick(flags: flags, button: button, mapping: mapping)
    }

    /// The last right-click's hit when it is fresh, once.
    func takeContextHit(now: ContinuousClock.Instant = .now) -> BrowserContextMenuTarget? {
        defer { contextHit = nil }
        guard let hit = contextHit, now - hit.at <= WebKitContextHit.freshness else { return nil }
        return hit.target
    }
}

/// What a link click with modifiers does in a WebKit tab.
enum WebKitLinkClick: Equatable {
    /// A plain click: the page's own behavior (a link loads here, a
    /// `target=_blank` link opens a selected tab).
    case pageDefault
    /// A modified click mapped to the current tab.
    case navigate
    case open(BrowserNewTabDisposition)
    case download

    /// What a click does in `tab` (`WebKitEngine.linkClicks`).
    @MainActor
    init(_ action: WKNavigationAction, in tab: WebKitTab) {
        self.init(flags: action.modifierFlags, button: action.buttonNumber, mapping: tab.engine?.linkClicks ?? .chrome)
    }

    /// Pure: the modifiers of a link click (`button` 2 is the middle button)
    /// through `mapping`.
    init(flags: NSEvent.ModifierFlags, button: Int, mapping: BrowserLinkClickMapping) {
        let gesture = BrowserLinkGesture(flags: flags, button: button)
        guard gesture != .plain else {
            self = .pageDefault
            return
        }
        let action = mapping.action(for: gesture)
        if let disposition = action.newTabDisposition {
            self = .open(disposition)
        } else {
            self = action == .download ? .download : .navigate
        }
    }

    /// A modified click mapped to the current tab or to a download, on a
    /// link that opens a page window: the opener loads or downloads it, and
    /// no page is created. False for every other click.
    @MainActor
    func runsInOpener(_ request: URLRequest, tab: WebKitTab) -> Bool {
        switch self {
        case .navigate:
            tab.webView.load(request)
        case .download:
            guard let url = request.url, WebKitTab.isWebScheme(url) else { return true }
            tab.webView.startDownload(using: request) { [weak tab] download in tab?.downloads.register(download, source: url) }
        case .open, .pageDefault:
            return false
        }
        return true
    }
}
