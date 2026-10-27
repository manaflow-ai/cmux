import CmuxNextCompat
public import Foundation

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
/// Every web tree imports React from `cmux-page://cmux.shared/`, the pages' `_shared` folder
/// (`PageID.sharedBundleRoot`), which maps into an update with this module's pages. So every page
/// that imports it is registered too (the agent pane, the webviews app, Agent Activity): a page and
/// the shared files it names then always come from the same update, and an update holds every shared
/// file its pages name (`WebUpdateTree.missingSharedFiles()` refuses one that does not).
///
/// Only the app's web updater activates a folder, after it checked the folder against a
/// signed pointer (``load(_:)`` at launch, ``activate(_:)`` for a new update); nothing a page
/// or a file says can point the app at other files.
///
/// A swap does not move a running document to the new files. Each document holds a ``Pin`` on the
/// tree it loaded from (the scheme handler takes one per main document load), and every later
/// request of that document, its lazy page chunks and `cmux.shared` chunks included, comes from
/// that tree (``root(for:pin:)``); ``liveTrees`` keeps the updater from pruning a pinned tree. A
/// hidden or frozen page that keeps its old document after a swap therefore never mixes two
/// builds' chunks, as Chrome keeps a renderer on the resources its document committed with until it
/// navigates (content/browser/renderer_host/navigation_controller_impl.cc, `SetNeedsReload`).
public nonisolated final class WebBundleOverlay: Sendable {
    public static let shared = WebBundleOverlay()

    /// Where this module's pages sit in the update layout (web-bundle-key.py OUTPUTS).
    public static let pagesOutput = "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
    /// Where the Agent Activity page sits in the update layout (web-bundle-key.py OUTPUTS). Its React is
    /// the shared one under ``pagesOutput``'s `_shared`, so the page is served from the same update as
    /// that folder (the app registers its bundled folder at launch).
    public static let agentActivityOutput = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"

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
        /// How many live documents loaded from each update folder (``Pin``).
        var pins: [URL: Int] = [:]
        /// A document was served (it took a pin), bundled or from an update.
        var servedDocument = false
    }

    /// A live document's hold on the update folder it loaded from (nil: the bundle). While the
    /// document lives its requests are served from ``tree`` (``root(for:pin:)``) and the folder stays
    /// in ``liveTrees``; the hold ends when the pin is freed (the document's next load replaces it, or
    /// its web view goes).
    public nonisolated final class Pin: Sendable {
        /// The update folder the document loaded from; nil for the bundled web.
        public let tree: URL?
        private let overlay: WebBundleOverlay

        fileprivate init(tree: URL?, overlay: WebBundleOverlay) {
            self.tree = tree
            self.overlay = overlay
            if let tree { overlay.state.withLock { $0.pins[tree, default: 0] += 1 } }
        }

        deinit {
            guard let tree else { return }
            overlay.state.withLock { held in
                let left = (held.pins[tree] ?? 1) - 1
                held.pins[tree] = left > 0 ? left : nil
            }
        }
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

    /// The update folders the app serves now: the active one and each one a live document still
    /// loads from (``Pin``). The updater never prunes them.
    public var liveTrees: [URL] {
        state.withLock { held in
            var trees = held.pins.keys.sorted { $0.path < $1.path }
            if let tree = held.tree, !trees.contains(tree) { trees.insert(tree, at: 0) }
            return trees
        }
    }

    /// Pins the folder a document that starts loading now is served from (after the launch check).
    public func pin() async -> Pin {
        let tree = await currentTree()
        state.withLock { $0.servedDocument = true }
        return Pin(tree: tree, overlay: self)
    }

    /// Whether a document already loaded its files (a launch that shows no page yet has none): a kept
    /// update found after that waits for a safe point.
    public var hasServedDocument: Bool { state.withLock { $0.servedDocument } }

    /// The folder to serve a request for the bundled root `bundled` from: inside `pin`'s folder for
    /// a request of a pinned document, else inside the folder served now.
    public func root(for bundled: URL, pin: Pin? = nil) async -> URL {
        let active: URL?
        if let pin { active = pin.tree } else { active = await currentTree() }
        guard let active else { return bundled }
        let bases = state.withLock { $0.bases }
        return Self.mapped(bundled, tree: active, bases: bases) ?? bundled
    }

    /// The folder served now, once the launch check settled.
    private func currentTree() async -> URL? {
        let (pending, tree) = state.withLock { ($0.pending, $0.tree) }
        if let pending { return await pending.value }
        return tree
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
