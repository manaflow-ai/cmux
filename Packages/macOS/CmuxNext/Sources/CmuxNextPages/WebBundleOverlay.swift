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
/// One registered output is one piece. A piece switched out by the signed switch file of the
/// channel (``setSwitches(_:)``, cmux-tui/crates/cmux-web-pieces) is served from another kept
/// update or from the bundle while the others stay on the active update; ``Serving`` is the whole
/// answer a page loads with.
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

    /// What every piece is served from: the active update and the pieces switched away from it.
    public nonisolated struct Serving: Equatable, Sendable {
        /// The active update's folder, nil for the bundle.
        public var tree: URL?
        /// The outputs switched out: each one's kept update folder, or nil for its bundled copy.
        public var switched: [String: URL?]

        public init(tree: URL?, switched: [String: URL?] = [:]) {
            self.tree = tree
            self.switched = switched
        }

        /// The folder `output` is served from (nil: the bundle).
        public func tree(forOutput output: String) -> URL? {
            if let other = switched[output] { return other }
            return tree
        }

        /// Every update folder this serves from.
        var trees: Set<URL> { Set(([tree] + switched.values).compactMap { $0 }) }
    }

    nonisolated struct State {
        var tree: URL?
        var switched: [String: URL?] = [:]
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

    /// Switches the outputs named in `switched` out of the active update, each to the kept update
    /// folder given or (nil) to its bundled copy, from the next request on; an output not named is
    /// served from the active update. Returns whether anything changed. Only the web updater calls
    /// it, with the answer of the verified switch file.
    @discardableResult
    public func setSwitches(_ switched: [String: URL?]) -> Bool {
        let switched = switched.mapValues { $0?.standardizedFileURL }
        return state.withLock { held in
            guard held.switched != switched else { return false }
            held.switched = switched
            return true
        }
    }

    /// The update folder served now, nil for the bundle (or while the launch check runs).
    public var activeTree: URL? { state.withLock { $0.tree } }

    /// The outputs switched out of the active update now.
    public var switches: [String: URL?] { state.withLock { $0.switched } }

    /// The update folders switched-out pieces are served from now (they stay on disk).
    public var switchedTrees: [URL] { state.withLock { $0.switched.values.compactMap { $0 } } }

    /// What a page that loads from `tree` now is served: `tree` with the switches of now.
    public func serving(tree: URL?) -> Serving {
        Serving(tree: tree?.standardizedFileURL, switched: switches)
    }

    /// What a new page loads from, once the launch check settled.
    public func serving() async -> Serving {
        serving(tree: await current())
    }

    /// The registered output that holds the bundled root `bundled`, nil when none does.
    public func output(for bundled: URL) -> String? {
        let path = Self.realPath(bundled)
        return state.withLock { $0.bases }.first { path == $0.bundled || path.hasPrefix($0.bundled + "/") }?.output
    }

    /// The folder to serve a request for the bundled root `bundled` from: the active update's.
    public func root(for bundled: URL) async -> URL {
        root(for: bundled, serving: await serving())
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

    /// The folder to serve a request for the bundled root `bundled` from under `serving`: inside
    /// the update its piece is served from, else the bundled root.
    public func root(for bundled: URL, serving: Serving) -> URL {
        guard serving.tree != nil || !serving.switched.isEmpty else { return bundled }
        let bases = state.withLock { $0.bases }
        return Self.mapped(bundled, serving: serving, bases: bases) ?? bundled
    }

    /// `bundled` inside `tree` when one of `bases` holds it, else nil.
    static func mapped(_ bundled: URL, tree: URL, bases: [Base]) -> URL? {
        mapped(bundled, serving: Serving(tree: tree), bases: bases)
    }

    /// `bundled` inside the update `serving` serves its piece from, when one of `bases` holds it
    /// and that piece is not served from the bundle; else nil.
    static func mapped(_ bundled: URL, serving: Serving, bases: [Base]) -> URL? {
        let path = realPath(bundled)
        for base in bases where path == base.bundled || path.hasPrefix(base.bundled + "/") {
            guard let tree = serving.tree(forOutput: base.output) else { return nil }
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
    /// What a view loaded with, and the outputs (pieces) its requests read.
    private struct Pin {
        var serving: WebBundleOverlay.Serving
        var outputs: Set<String> = []
    }

    private var pins: [ObjectIdentifier: Pin] = [:]

    /// The tree `view` loaded from (`.some(nil)`: the bundle), nil before its first request.
    func tree(for view: ObjectIdentifier) -> URL?? { pins[view].map(\.serving.tree) }

    /// What `view` loaded with, nil before its first request.
    func serving(for view: ObjectIdentifier) -> WebBundleOverlay.Serving? { pins[view]?.serving }

    mutating func pin(_ view: ObjectIdentifier, to tree: URL?) { pin(view, to: WebBundleOverlay.Serving(tree: tree)) }

    /// `view` reads `serving` from now on; the outputs it read before stay known.
    mutating func pin(_ view: ObjectIdentifier, to serving: WebBundleOverlay.Serving) {
        pins[view] = Pin(serving: serving, outputs: pins[view]?.outputs ?? [])
    }

    /// `view` read a file of `output`.
    mutating func read(_ view: ObjectIdentifier, output: String) { pins[view]?.outputs.insert(output) }

    /// Forgets `view` (a new web view that may reuse a gone one's identity).
    mutating func forget(_ view: ObjectIdentifier) { pins[view] = nil }

    /// Keeps only `live`'s pins.
    mutating func keep(_ live: Set<ObjectIdentifier>) { pins = pins.filter { live.contains($0.key) } }

    /// Whether `view` still reads a tree other than `tree` (a view with no pin yet loads `tree`).
    func isBehind(_ view: ObjectIdentifier, _ tree: URL?) -> Bool {
        isBehind(view, WebBundleOverlay.Serving(tree: tree, switched: pins[view]?.serving.switched ?? [:]))
    }

    /// Whether `view` reads a piece from another folder than `serving` names for it (a view with
    /// no pin yet loads `serving`). A view that read no registered output is compared by the
    /// active update alone; a switch of a piece it does not read never reloads it.
    func isBehind(_ view: ObjectIdentifier, _ serving: WebBundleOverlay.Serving) -> Bool {
        guard let pin = pins[view] else { return false }
        guard !pin.outputs.isEmpty else { return pin.serving.tree != serving.tree }
        return pin.outputs.contains { pin.serving.tree(forOutput: $0) != serving.tree(forOutput: $0) }
    }

    /// The update trees pages read now, which must stay on disk.
    var pinned: Set<URL> { pins.values.reduce(into: []) { $0.formUnion($1.serving.trees) } }
}

/// A host that keeps what its page shows on screen while the page reloads in place for a web update or the live
/// web loop (``WebBundleServedViews/reload(_:to:)``): the reload shows no blank page, no loading state and no
/// composer drawn again, only the new page in one step once it drew (Leo, 2026-11-22: "no shift, no anything,
/// just... ok now it changed").
public protocol WebReloadCovering: AnyObject {
    /// Runs `reload` (the page's reload) with the page as it draws now held on screen until the reloaded
    /// document drew. It runs `reload` once, at once or after a picture is taken.
    func reloadUnderCover(_ reload: @escaping @MainActor () -> Void)
    /// Whether ``reloadUnderCover(_:)`` would hold the page on screen now (false: it reloads it bare).
    var coversNextReload: Bool { get }
}

/// The web views the page and agent pane scheme handlers served, and the update each loaded from,
/// so an update that becomes active reloads them in place, each at its own safe point.
public final class WebBundleServedViews {
    public static let shared = WebBundleServedViews()

    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private var pins = WebBundlePins()
    /// Views that keep the update they loaded with until they close (``keepLoadedTree(_:)``).
    private let keepsLoaded = NSHashTable<WKWebView>.weakObjects()
    /// The host that covers each view's reload (``coverReloads(of:with:)``).
    private let covers = NSMapTable<WKWebView, AnyObject>.weakToWeakObjects()

    /// `cover` keeps `webView`'s page on screen through each in-place reload (``WebReloadCovering``).
    public func coverReloads(of webView: WKWebView, with cover: any WebReloadCovering) {
        covers.setObject(cover, forKey: webView)
    }

    /// Whether `webView`'s host holds its page on screen through the next reload: the graceful reload
    /// (``WebBundleGracefulReload``) lays no picture of its own over such a page.
    public func coversReload(of webView: WKWebView) -> Bool {
        (covers.object(forKey: webView) as? any WebReloadCovering)?.coversNextReload ?? false
    }

    /// `webView` keeps the update it loaded with until it closes: a newer update never reloads it in
    /// place (``behind(_:)`` skips it), and its tree stays on disk while it is open (``pinnedTrees``).
    /// For a small page that is always in sight and has nothing to gain from a swap: the sidebar's
    /// Updated card reloaded, blank for a few frames and then its words again, at every merge the
    /// every-merge channel published (Leo 2026-11-07: "this updated to nightly thing also sometimes
    /// flickers"). It takes the newer web the next time it opens.
    public func keepLoadedTree(_ webView: WKWebView) {
        keepsLoaded.add(webView)
    }

    /// Whether `webView` keeps the update it loaded with until it closes (``keepLoadedTree(_:)``).
    public func keepsLoadedTree(_ webView: WKWebView) -> Bool { keepsLoaded.contains(webView) }

    /// A Chromium page's document request: the page (keyed by its host `webView`, which Chromium
    /// draws for) reads the update active now from this document on, and every request of the
    /// document after it reads that same update (``root(for:in:overlay:)``), so its lazy chunks never
    /// come from a newer build than its entry (an unhashed `chunks/X.mjs` of the next merge's build
    /// under the last one's entry). Its tree stays on disk while it is open (``pinnedTrees``), and a
    /// swap never reloads it in place (``keepLoadedTree(_:)``): it takes the newer web with its next
    /// document (a reload, a restart, a reopen).
    public func chromiumDocument(_ webView: WKWebView) {
        webViews.add(webView)
        keepsLoaded.add(webView)
        pins.forget(ObjectIdentifier(webView))
    }

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
        let output = overlay.output(for: bundled)
        if let pinned = pins.serving(for: view) { return root(for: bundled, view, output, pinned, overlay) }
        let serving = await overlay.serving()
        // Another request of the same page may have pinned it while this one waited.
        if let pinned = pins.serving(for: view) { return root(for: bundled, view, output, pinned, overlay) }
        pins.pin(view, to: serving)
        return root(for: bundled, view, output, serving, overlay)
    }

    /// `bundled` under `serving`, noting that `view` reads `output` (so a switch of that piece
    /// reloads it, and a switch of another does not).
    private func root(for bundled: URL, _ view: ObjectIdentifier, _ output: String?, _ serving: WebBundleOverlay.Serving,
                      _ overlay: WebBundleOverlay) -> URL {
        if let output { pins.read(view, output: output) }
        return overlay.root(for: bundled, serving: serving)
    }

    /// The served views that show a document.
    public var shown: [WKWebView] { webViews.allObjects.filter { $0.url != nil } }

    /// The shown views that still read another tree than `tree` (nil: the bundle), less the ones that
    /// keep their tree until they close (``keepLoadedTree(_:)``).
    public func behind(_ tree: URL?) -> [WKWebView] {
        let live = webViews.allObjects
        pins.keep(Set(live.map(ObjectIdentifier.init)))
        return live.filter { $0.url != nil && !keepsLoaded.contains($0) && pins.isBehind(ObjectIdentifier($0), tree) }
    }

    /// The shown views that read a piece from another folder than `serving` names for it, less the
    /// ones that keep their tree until they close (``keepLoadedTree(_:)``).
    public func behind(_ serving: WebBundleOverlay.Serving) -> [WKWebView] {
        let live = webViews.allObjects
        pins.keep(Set(live.map(ObjectIdentifier.init)))
        return live.filter { $0.url != nil && !keepsLoaded.contains($0) && pins.isBehind(ObjectIdentifier($0), serving) }
    }

    /// The update trees open pages read now (they stay on disk until those pages reload).
    public var pinnedTrees: [URL] {
        pins.keep(Set(webViews.allObjects.map(ObjectIdentifier.init)))
        return Array(pins.pinned)
    }

    /// Reloads `views` from `tree` (nil: the bundle). Returns how many it reloaded. A page's view swaps
    /// in place with no visible reload (``PageWebView/swapReload()``); another view reloads as before.
    @discardableResult
    public func reload(_ views: [WKWebView], to tree: URL?) -> Int {
        for webView in views { pins.pin(ObjectIdentifier(webView), to: tree) }
        swapReloadCovered(views)
        return views.count
    }

    /// Reloads `views` under `serving`, each in place with no visible reload (``swapReload(_:)``).
    /// Returns how many it reloaded.
    @discardableResult
    public func reload(_ views: [WKWebView], to serving: WebBundleOverlay.Serving) -> Int {
        for webView in views { pins.pin(ObjectIdentifier(webView), to: serving) }
        swapReloadCovered(views)
        return views.count
    }

    /// Reloads `views` in place: one whose host holds its page on screen (the agent chat,
    /// `AgentPaneView+ReloadCover`) through that host, every other one with the hand-off and its still
    /// (``swapReload(_:)``).
    private func swapReloadCovered(_ views: [WKWebView]) {
        var rest: [WKWebView] = []
        for webView in views {
            if let cover = covers.object(forKey: webView) as? any WebReloadCovering, cover.coversNextReload {
                cover.reloadUnderCover { [weak webView] in webView?.reload() }
            } else {
                rest.append(webView)
            }
        }
        Self.swapReload(rest)
    }

    /// Reloads each of `views` into the web it is served now: a page's view in place with no visible
    /// reload (``PageWebView/swapReload()``), any other view as before.
    public static func swapReload(_ views: [WKWebView]) {
        guard !views.isEmpty else { return }
        let pages = PageRegistry.pages()
        for webView in views {
            guard let page = pages.first(where: { $0.webKitView === webView }) else {
                // An agent chat's pane (not a page view): the same hand-off and still (WebViewSwap.swift).
                // task-owner: one swap per view; it ends with the view's restored frame or its cover limit
                Task { await WebViewSwap.reload(webView) }
                continue
            }
            // task-owner: one swap per page; it ends with the page's restored frame or its cover limit
            Task { await page.swapReload() }
        }
    }

    /// Reloads every served view that shows a document from the folder now active. Returns how
    /// many it reloaded.
    @discardableResult
    public func reloadServed(overlay: WebBundleOverlay = .shared) -> Int {
        reload(shown, to: overlay.serving(tree: overlay.activeTree))
    }
}
