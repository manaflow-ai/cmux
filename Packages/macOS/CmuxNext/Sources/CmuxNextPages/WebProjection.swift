public import AppKit
public import WebKit

/// Projection windows (manaflow-ai/cmuxterm-hq#7149 L10): one window of the running app whose pages
/// and agent panes load from a worktree's dev server, while every other window keeps what it shows.
/// The window is a real window of this app, so it draws with the person's own settings, theme,
/// backdrop and keys, and its terminals and agents are the live daemon's. Only its web files differ.
///
/// The page and agent pane scheme handlers ask ``server(for:)`` per request: a web view inside a
/// bound window loads from that window's server (the same fetch and fallback as `web-dev.json`'s
/// `server`, ``WebDevOverride``), any other one from ``WebDevOverride/current``. Binding reloads the
/// window's pages; a page that made its first request before it was in a window is checked again
/// once it is (``served(_:)``). NIGHTLY, cmux NEXT DEV and Debug only (``WebDevOverride/isEnabled``).
public final class WebProjection {
    public static let shared = WebProjection()

    public init() {}

    private struct Binding {
        weak var window: NSWindow?
        let server: PageDevServer
    }

    private var bindings: [ObjectIdentifier: Binding] = [:]
    /// The server root each web view's last request read (nil: not a projection), so a pass reloads
    /// only the views whose window now says otherwise.
    private let servedFrom = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()
    private let unbound = NSURL(string: "about:blank") ?? NSURL()
    private var recheck: Task<Void, Never>?

    /// Whether any window is a projection now.
    public var isActive: Bool {
        bindings = bindings.filter { $0.value.window != nil }
        return !bindings.isEmpty
    }

    /// The server `webView` loads from: its window's projection server, nil for none.
    public func server(for webView: WKWebView?) -> PageDevServer? {
        guard !bindings.isEmpty, let window = webView?.window else { return nil }
        return bindings[ObjectIdentifier(window)]?.server
    }

    /// The override in force for `webView`: ``WebDevOverride/current`` with its window's projection
    /// server, when it has one.
    public func override(for webView: WKWebView?) -> WebDevOverride {
        var value = WebDevOverride.current
        if let server = server(for: webView) { value.server = server }
        return value
    }

    /// Makes `window` a projection of `server` and reloads its pages. Returns how many it reloaded, or
    /// nil when this build reads no live web override (Release, RC).
    @discardableResult
    public func bind(_ window: NSWindow, server: PageDevServer) -> Int? {
        guard WebDevOverride.isEnabled else { return nil }
        bindings[ObjectIdentifier(window)] = Binding(window: window, server: server)
        return reloadStale()
    }

    /// Ends `window`'s projection; its pages reload from where every other window's do.
    @discardableResult
    public func unbind(_ window: NSWindow) -> Int {
        guard bindings.removeValue(forKey: ObjectIdentifier(window)) != nil else { return 0 }
        return reloadStale()
    }

    /// A scheme handler is answering a request of `webView`: records where it read from. A view with
    /// no window yet (a page built before its tab is shown) is checked again shortly, so a page that
    /// first loads the shipped files and then lands in a projection window reloads from its server.
    func served(_ webView: WKWebView) {
        guard !bindings.isEmpty else { return }
        servedFrom.setObject(server(for: webView).map { $0.root as NSURL } ?? unbound, forKey: webView)
        guard webView.window == nil, recheck == nil else { return }
        recheck = Task { [weak self] in // task-owner: one coalesced pass after windowless requests
            try? await Task.sleep(for: .milliseconds(300))
            self?.recheck = nil
            self?.reloadStale()
        }
    }

    /// Reloads every shown view whose last request read another server than its window says now.
    @discardableResult
    func reloadStale() -> Int {
        var stale: [WKWebView] = []
        for webView in WebBundleServedViews.shared.shown where webView.window != nil {
            let want = server(for: webView).map { $0.root as NSURL } ?? unbound
            let had = servedFrom.object(forKey: webView) ?? unbound
            guard had != want else { continue }
            servedFrom.setObject(want, forKey: webView)
            stale.append(webView)
        }
        for webView in stale { webView.reload() }
        return stale.count
    }
}
