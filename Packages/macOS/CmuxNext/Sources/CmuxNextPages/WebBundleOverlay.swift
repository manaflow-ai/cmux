import CmuxNextCompat
public import Foundation
public import WebKit

/// The verified web update the app serves ahead of the web bundles it shipped with
/// (plans/cmux-next/web-ota.md).
///
/// An update is a folder with the repository layout of `build-web-bundles.sh --out-root`
/// (`Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/...`). Each bundled web
/// output is registered once with the path it has in that layout (``register(bundled:output:)``;
/// the pages of this module register themselves). A scheme handler keeps serving under its
/// bundled root and asks ``root(for:)`` on every request: the same folder inside the active
/// update, else the bundled root. The web-dev.json server and overlay (live reload) stay ahead
/// of it, so the order is dev server, dev overlay, update, bundle.
///
/// Only the app's web updater activates a folder, after it checked the folder against a
/// signed pointer (``load(_:)`` at launch, ``activate(_:)`` for a new update); nothing a page
/// or a file says can point the app at other files.
public nonisolated final class WebBundleOverlay: Sendable {
    public static let shared = WebBundleOverlay()

    /// Where this module's pages sit in the update layout (web-bundle-key.py OUTPUTS).
    public static let pagesOutput = "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"

    nonisolated struct Base: Equatable {
        /// The bundled folder's real path.
        let bundled: String
        /// Its path inside an update.
        let output: String
    }

    nonisolated struct State {
        var tree: URL?
        var bases: [Base] = []
        /// The launch check of the kept update; requests wait for it.
        var pending: Task<URL?, Never>?
    }

    private let state: Mutex<State>

    init(bases: [Base] = WebBundleOverlay.moduleBases) {
        state = Mutex(State(bases: bases))
    }

    /// This module's bundled pages folder (it holds `web-abi.json`).
    public static var bundledPages: URL? { Bundle.module.url(forResource: "pages", withExtension: nil) }

    static var moduleBases: [Base] {
        guard let pages = bundledPages else { return [] }
        return [Base(bundled: Self.realPath(pages), output: pagesOutput)]
    }

    /// Names where the bundled folder `bundled` sits in an update (`output`, repository relative).
    public func register(bundled: URL, output: String) {
        guard !output.isEmpty, !output.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return }
        let base = Base(bundled: Self.realPath(bundled), output: output)
        state.withLock { held in
            if !held.bases.contains(base) { held.bases.append(base) }
        }
    }

    /// Starts the launch check of the kept update: requests wait for `check`, then serve the
    /// folder it returns (nil serves the bundle).
    public func load(_ check: @escaping @Sendable () async -> URL?) {
        let task = Task { await check() } // task-owner: the launch check; held in `pending` until it settles
        state.withLock { $0.pending = task }
        // task-owner: settles the launch check once; the check ends by itself
        Task {
            let tree = await task.value
            self.state.withLock { held in
                guard held.pending == task else { return }
                held.pending = nil
                held.tree = tree
            }
        }
    }

    /// Serves `tree` (nil: the bundle) from the next request on; returns whether it changed.
    @discardableResult
    public func activate(_ tree: URL?) -> Bool {
        let tree = tree?.standardizedFileURL
        return state.withLock { held in
            held.pending = nil
            guard held.tree != tree else { return false }
            held.tree = tree
            return true
        }
    }

    /// The update folder served now, nil for the bundle (or while the launch check runs).
    public var activeTree: URL? { state.withLock { $0.tree } }

    /// The folder to serve a request for the bundled root `bundled` from.
    public func root(for bundled: URL) async -> URL {
        let (pending, tree, bases) = state.withLock { ($0.pending, $0.tree, $0.bases) }
        var active = tree
        if let pending { active = await pending.value }
        guard let active else { return bundled }
        return Self.mapped(bundled, tree: active, bases: bases) ?? bundled
    }

    /// `bundled` inside `tree` when one of `bases` holds it, else nil.
    static func mapped(_ bundled: URL, tree: URL, bases: [Base]) -> URL? {
        let path = realPath(bundled)
        for base in bases where path == base.bundled || path.hasPrefix(base.bundled + "/") {
            let rest = path.dropFirst(base.bundled.count)
            return tree.appending(path: base.output + rest, directoryHint: .isDirectory)
        }
        return nil
    }

    static func realPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The web views the page and agent pane scheme handlers served, so an update that becomes
/// active reloads them in place (``reloadServed()``).
public final class WebBundleServedViews {
    public static let shared = WebBundleServedViews()

    private let webViews = NSHashTable<WKWebView>.weakObjects()

    /// Whether no handler served a view yet (a launch that shows no page).
    public var isEmpty: Bool { webViews.allObjects.isEmpty }

    /// Adds `webView`, which a bundled page scheme handler is serving.
    public func add(_ webView: WKWebView) {
        webViews.add(webView)
    }

    /// The served views that show a document.
    public var shown: [WKWebView] { webViews.allObjects.filter { $0.url != nil } }

    /// Reloads every served view that shows a document; the scheme handler answers the same URLs
    /// from the folder now active. Returns how many it reloaded.
    @discardableResult
    public func reloadServed() -> Int {
        let shown = shown
        for webView in shown { webView.reload() }
        return shown.count
    }
}
