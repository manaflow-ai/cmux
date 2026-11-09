public import AppKit
import CmuxNextWakeups
public import Foundation
import os
public import WebKit

/// Projection windows (manaflow-ai/cmuxterm-hq#7149 L10): one window of the running app whose pages
/// and agent panes load from a worktree's dev server, while every other window keeps what it shows.
/// The window is a real window of this app, so it draws with the person's own settings, theme,
/// backdrop and keys, and its terminals and agents are the live daemon's. Only its web files differ.
/// Leo, 2026-11-05: "there's even the glass, like the actual glass with your actual config, your
/// actual settings. That's the point."
///
/// - `debug.projection` (Debug > Open Projection Window; `cmux action run debug.projection --server
///   http://127.0.0.1:4290/ --worktree ~/src/wt --test 'bun test src/x.test.ts'`, which
///   `scripts/cmux-next/projection.sh` runs): ``open(server:worktree:test:)`` names a new window, and
///   CmuxNextApp (`ChiefViewsPageTab.bindProjection`) opens it on a workspace in the worktree, showing
///   the New Tab page.
/// - `debug.projection.runTest` (Debug > Run Projection Test): ``testRun(in:test:)`` picks the
///   projection, and the app runs its test command in a new workspace of that window.
///
/// The page and agent pane scheme handlers ask ``server(for:)`` per request: a web view whose window
/// is a projection's (``windowID``, which the app sets) loads from that server, with the same fetch
/// and fallback as `web-dev.json`'s `server` (``WebDevOverride``); any other one reads
/// ``WebDevOverride/current``. While a projection window is open, new pages open in WebKit in every
/// window, as with `web-dev.json` (Chromium serves only its bundled files). A page that made its first request before it was in a window is
/// checked again shortly after (``served(_:)``). NIGHTLY, cmux NEXT DEV and Debug only
/// (``WebDevOverride/isEnabled``).
public final class WebProjection {
    public static let shared = WebProjection()
    public static let openID = "debug.projection"
    public static let runTestID = "debug.projection.runTest"
    /// The port `web-overlay.sh server` uses; `projection.sh` passes its own.
    public static let defaultServer = "http://127.0.0.1:4200/"
    /// Where each document load read from and each reload, for a check that sees only the app's log.
    private let log = Logger(subsystem: "com.cmuxterm.app.next", category: "projection")

    public struct Projection: Sendable, Equatable {
        public let windowID: String
        public let server: PageDevServer
        public var worktree: String?
        public var test: String?
    }

    /// Why an open or a test run did not start.
    public struct Refusal: Error, Equatable {
        public let message: String
    }

    /// Opened projections, newest last. A projection whose window has not shown yet or has closed stays
    /// listed and matches no web view.
    public private(set) var projections: [Projection] = []
    /// The app's id of the window `window` is or belongs to (CmuxNextApp's window state id), nil for none.
    public var windowID: (NSWindow) -> String? = { _ in nil }
    /// Whether the app has the window `id` open now.
    public var isOpen: (String) -> Bool = { _ in false }
    /// The server root each web view's last request read (`unbound`: not a projection), so a pass
    /// reloads only the views whose window now says otherwise.
    private let servedFrom = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()
    private let unbound = NSURL(string: "about:blank") ?? NSURL()
    private let recheck = DemandTimer(owner: "WebProjection.recheck")

    public init() {}

    /// Projection windows seen open, so one that closes ends its projection for good (a window reopened
    /// under the same id is an ordinary window).
    private var shown: Set<String> = []

    /// Whether any open window is a projection now.
    public var isActive: Bool {
        prune()
        return !shown.isEmpty
    }

    /// The server `webView` loads from: its window's projection server, nil for none.
    public func server(for webView: WKWebView?) -> PageDevServer? {
        guard !projections.isEmpty, let window = webView?.window, let id = windowID(window) else { return nil }
        prune()
        return projections.last { $0.windowID == id }?.server
    }

    /// Drops the projections whose window showed and has closed since.
    private func prune() {
        for projection in projections where isOpen(projection.windowID) { shown.insert(projection.windowID) }
        let closed = shown.filter { !isOpen($0) }
        guard !closed.isEmpty else { return }
        projections.removeAll { closed.contains($0.windowID) }
        shown.subtract(closed)
    }

    /// The override in force for `webView`: ``WebDevOverride/current`` with its window's projection
    /// server, when it has one.
    public func override(for webView: WKWebView?) -> WebDevOverride {
        var value = WebDevOverride.current
        if let server = server(for: webView) { value.server = server }
        return value
    }

    /// A new projection of `server` (default ``defaultServer``) for a new window, with the worktree
    /// its terminal and test start in and the test command Run Projection Test runs.
    public func open(server: String?, worktree: String?, test: String?) throws(Refusal) -> Projection {
        guard WebDevOverride.isEnabled else { throw Refusal(message: Self.unavailable) }
        let raw = server.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultServer
        guard let root = PageDevServer.loopbackURL(raw) else { throw Refusal(message: Self.notLoopback) }
        let projection = Projection(windowID: UUID().uuidString.lowercased(), server: PageDevServer(root: root),
                                    worktree: worktree.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath },
                                    test: test.flatMap { $0.isEmpty ? nil : $0 })
        projections.append(projection)
        log.notice("open \(projection.windowID, privacy: .public) \(root.absoluteString, privacy: .public)")
        return projection
    }

    /// The projection a test run goes to: the one whose window is `windowID` (the active window), else
    /// the newest open one. A non-empty `test` replaces its test command.
    public func testRun(in windowID: String?, test: String?) throws(Refusal) -> Projection {
        prune()
        guard let index = projections.lastIndex(where: { $0.windowID == windowID })
            ?? projections.lastIndex(where: { isOpen($0.windowID) })
        else { throw Refusal(message: Self.noProjection) }
        if let test, !test.isEmpty { projections[index].test = test }
        guard projections[index].test != nil else { throw Refusal(message: Self.noTest) }
        return projections[index]
    }

    /// A scheme handler is answering a request of `webView`: a document load (`isDocument`) records where
    /// the page read from. A view with no window yet (a page built before its tab is shown) is checked
    /// again until it has one, so a page that first loads the shipped files and then lands in a projection
    /// window reloads from its server.
    public func served(_ webView: WKWebView, isDocument: Bool) {
        guard !projections.isEmpty, isDocument else { return }
        let from = server(for: webView)
        let url = webView.url?.absoluteString ?? "-", window = webView.window.flatMap(windowID) ?? "none"
        let read = from?.root.absoluteString ?? "bundle"
        let open = projections.map { "\($0.windowID):\(isOpen($0.windowID))" }.joined(separator: ",")
        log.notice("document \(url, privacy: .public) window \(window, privacy: .public) from \(read, privacy: .public) projections \(open, privacy: .public)")
        servedFrom.setObject(from.map { $0.root as NSURL } ?? unbound, forKey: webView)
        guard webView.window == nil else { return }
        windowlessChecks = 0
        scheduleRecheck()
    }

    /// Passes left for views that loaded with no window: 40 at 300 ms, about 12 s for a window to show.
    private var windowlessChecks = 0

    private func scheduleRecheck() {
        recheck.scheduleIfIdle(after: .milliseconds(300)) { @MainActor [weak self] in
            guard let self else { return }
            reloadStale()
            windowlessChecks += 1
            let waiting = WebBundleServedViews.shared.shown.contains { $0.window == nil && self.servedFrom.object(forKey: $0) != nil }
            if waiting, windowlessChecks < 40 { scheduleRecheck() }
        }
    }

    /// Reloads every shown view whose last request read another server than its window says now.
    @discardableResult
    public func reloadStale() -> Int {
        var stale: [WKWebView] = []
        for webView in WebBundleServedViews.shared.shown where webView.window != nil {
            let want = server(for: webView).map { $0.root as NSURL } ?? unbound
            guard (servedFrom.object(forKey: webView) ?? unbound) != want else { continue }
            servedFrom.setObject(want, forKey: webView)
            stale.append(webView)
        }
        for webView in stale { webView.reload() }
        if !stale.isEmpty { log.notice("reloaded \(stale.count) page(s) for their window's server") }
        return stale.count
    }

    /// The name of a projection window's first workspace.
    public static func workspaceName(_ worktree: String?) -> String {
        let folder = worktree.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        return folder.map { String(format: t("projection.workspace.named", "Projection: %@"), $0) } ?? t("projection.workspace", "Projection")
    }

    /// Why the projection actions are unavailable: Release and RC builds. Nil when they run.
    public static var unavailableReason: String? { WebDevOverride.isEnabled ? nil : unavailable }
    public static var testName: String { t("projection.workspace.test", "Projection Test") }
    static var unavailable: String { t("projection.refusal.off", "Projection windows are only in NIGHTLY and DEV builds.") }
    static var notLoopback: String { t("projection.refusal.notLoopback", "The projection's server must be a local address.") }
    static var noProjection: String { t("projection.refusal.none", "No projection window is open.") }
    static var noTest: String { t("projection.refusal.noTest", "This projection has no test. Pass one with --test.") }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
