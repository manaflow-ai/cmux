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
/// bundled root and asks on every request for the same folder inside an update, else the bundled
/// root: a web view's request reads the update that page loaded with
/// (``WebBundleServedViews/root(for:in:overlay:)``), any other the active one (``root(for:)``).
/// The web-dev.json server and overlay (live reload) stay ahead
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

    /// The folder to serve a request for the bundled root `bundled` from: the active update's.
    public func root(for bundled: URL) async -> URL {
        root(for: bundled, tree: await current())
    }

    /// The update folder a new page loads from (nil: the bundle), once the launch check settled.
    public func current() async -> URL? {
        let (pending, tree) = state.withLock { ($0.pending, $0.tree) }
        if let pending { return await pending.value }
        return tree
    }

    /// The folder to serve a request for the bundled root `bundled` from inside `tree` (nil: the bundle).
    public func root(for bundled: URL, tree: URL?) -> URL {
        guard let tree else { return bundled }
        let bases = state.withLock { $0.bases }
        return Self.mapped(bundled, tree: tree, bases: bases) ?? bundled
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

/// Which update each served page loaded from (plans/cmux-next/web-ota.md, "The safe point"). A
/// page reads the tree it loaded with until it reloads, so an update swaps in page by page and an
/// open page never mixes two builds' chunks (a lazy import, a stylesheet) while another reloads.
nonisolated struct WebBundlePins {
    private var trees: [ObjectIdentifier: URL?] = [:]

    /// The tree `view` loaded from (`.some(nil)`: the bundle), nil before its first request.
    func tree(for view: ObjectIdentifier) -> URL?? { trees[view] }

    mutating func pin(_ view: ObjectIdentifier, to tree: URL?) { trees[view] = .some(tree) }

    /// Forgets `view` (a new web view that may reuse a gone one's identity).
    mutating func forget(_ view: ObjectIdentifier) { trees[view] = nil }

    /// Keeps only `live`'s pins.
    mutating func keep(_ live: Set<ObjectIdentifier>) { trees = trees.filter { live.contains($0.key) } }

    /// Whether `view` still reads a tree other than `tree` (a view with no pin yet loads `tree`).
    func isBehind(_ view: ObjectIdentifier, _ tree: URL?) -> Bool {
        guard let pinned = trees[view] else { return false }
        return pinned != tree
    }

    /// The update trees pages read now, which must stay on disk.
    var pinned: Set<URL> { Set(trees.values.compactMap { $0 }) }
}

/// The web views the page and agent pane scheme handlers served, and the update each loaded from,
/// so an update that becomes active reloads them in place, each at its own safe point.
public final class WebBundleServedViews {
    public static let shared = WebBundleServedViews()

    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private var pins = WebBundlePins()

    /// Whether no handler served a view yet (a launch that shows no page).
    public var isEmpty: Bool { webViews.allObjects.isEmpty }

    /// Adds `webView`, which a bundled page scheme handler is serving.
    public func add(_ webView: WKWebView) {
        if !webViews.contains(webView) { pins.forget(ObjectIdentifier(webView)) }
        webViews.add(webView)
    }

    /// The folder to serve `webView`'s request for the bundled root `bundled` from: inside the
    /// tree that page loaded with, which its first request pins to the update active then.
    public func root(for bundled: URL, in webView: WKWebView, overlay: WebBundleOverlay = .shared) async -> URL {
        let view = ObjectIdentifier(webView)
        if let pinned = pins.tree(for: view) { return overlay.root(for: bundled, tree: pinned) }
        let tree = await overlay.current()
        // Another request of the same page may have pinned it while this one waited.
        if let pinned = pins.tree(for: view) { return overlay.root(for: bundled, tree: pinned) }
        pins.pin(view, to: tree)
        return overlay.root(for: bundled, tree: tree)
    }

    /// The served views that show a document.
    public var shown: [WKWebView] { webViews.allObjects.filter { $0.url != nil } }

    /// The shown views that still read another tree than `tree` (nil: the bundle).
    public func behind(_ tree: URL?) -> [WKWebView] {
        let live = webViews.allObjects
        pins.keep(Set(live.map(ObjectIdentifier.init)))
        return live.filter { $0.url != nil && pins.isBehind(ObjectIdentifier($0), tree) }
    }

    /// The update trees open pages read now (they stay on disk until those pages reload).
    public var pinnedTrees: [URL] {
        pins.keep(Set(webViews.allObjects.map(ObjectIdentifier.init)))
        return Array(pins.pinned)
    }

    /// Reloads `views` from `tree` (nil: the bundle). Returns how many it reloaded.
    @discardableResult
    public func reload(_ views: [WKWebView], to tree: URL?) -> Int {
        for webView in views {
            pins.pin(ObjectIdentifier(webView), to: tree)
            webView.reload()
        }
        return views.count
    }

    /// Reloads every served view that shows a document from the folder now active. Returns how
    /// many it reloaded.
    @discardableResult
    public func reloadServed(overlay: WebBundleOverlay = .shared) -> Int {
        reload(shown, to: overlay.activeTree)
    }
}
