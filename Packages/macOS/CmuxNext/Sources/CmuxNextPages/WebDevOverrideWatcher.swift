import CmuxNextSettings
public import Foundation
import os
public import WebKit

/// Watches `web-dev.json` and the overlay's `manifest.json` (``WebDevOverride``), keeps
/// ``WebDevOverride/current`` and reloads every web view the page and agent pane scheme handlers
/// served on a change (``WebBundleServedViews``, the one list a web UI update also reloads). Does
/// nothing unless ``WebDevOverride/isEnabled``.
public final class WebDevOverrideWatcher {
    public static let shared = WebDevOverrideWatcher()

    /// Runs after a page did not start from the overlay and every page fell back to the bundled ones
    /// (``WebDevOverride/overlayDidNotStart(_:page:why:)``), with the one-line reason: the app says
    /// why and turns the layer off (`cmux customize library off --code`).
    public var onFallBack: ((String) -> Void)?

    private var fileWatcher: ConfigFileWatcher?
    private var manifestWatcher: ConfigFileWatcher?
    private var file: URL?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var readTask: Task<Void, Never>?
    private var readRequested = false
    /// Whether Chromium pages were serving the live loop after the last ``reloadPages(live:hosting:pages:served:watcher:)``.
    private var chromiumServedLive = false
    /// Counts ``reloadPages(live:hosting:pages:served:watcher:)`` calls, so an engine move a later reload
    /// superseded does not finish.
    private var reloadGeneration = 0

    /// A page or agent pane scheme handler is serving `webView`, from any of its paths (bundled
    /// file, dev server, overlay): it joins ``WebBundleServedViews`` so a change reloads it, and the
    /// first one starts the watch, so a launch that shows no page reads nothing (the first page
    /// loads bundled and reloads once the file is read).
    public func served(_ webView: WKWebView) {
        guard WebDevOverride.isEnabled else { return }
        WebBundleServedViews.shared.add(webView)
        start()
    }

    /// Arms the watch on `web-dev.json` in `configDirectory` (nil: next to `cmux-next.json`) and
    /// reads it once. Does nothing while running or unless ``WebDevOverride/isEnabled``.
    public func start(configDirectory: URL? = nil) {
        guard WebDevOverride.isEnabled, fileWatcher == nil else { return }
        let directory = configDirectory ?? CmuxConfigFile.defaultURL().deletingLastPathComponent()
        let file = directory.appending(path: WebDevOverride.fileName)
        self.file = file
        let watcher = ConfigFileWatcher(url: file) { [weak self] in
            Task { @MainActor in self?.requestRead() } // task-owner: one coalesced read per file event
        }
        fileWatcher = watcher
        watcher.start()
    }

    private func requestRead() {
        guard file != nil else { return }
        readRequested = true
        guard readTask == nil else { return }
        readTask = Task { [weak self] in // task-owner: the watcher's one read loop; events while it runs coalesce
            while let file = self?.takeReadRequest(), let home = self?.home {
                let value = await Self.read(file: file, home: home)
                self?.apply(value)
            }
            self?.readTask = nil
        }
    }

    private func takeReadRequest() -> URL? {
        guard readRequested else { return nil }
        readRequested = false
        return file
    }

    @concurrent private static func read(file: URL, home: URL) async -> WebDevOverride {
        // concurrency-allow: @concurrent, so the file reads never run on the main actor
        WebDevOverride.read(file: file, home: home)
    }

    private func apply(_ value: WebDevOverride) {
        watchManifest(of: value.overlay)
        guard WebDevOverride.update(value) else { return }
        if let refusal = value.refusal {
            Logger(subsystem: "com.cmuxterm.app.next", category: "web-dev").notice("overlay refused: \(refusal, privacy: .public)")
        }
        Self.reloadPages(background: value.background)
    }

    /// Reloads every page and agent pane from where the override now says, in both engines: the
    /// same URL again, which the WebKit scheme handlers and (with ``PageChromiumHosting/setLivePages(_:)``)
    /// Chromium's page host answer from the dev server, the overlay, a web update or the bundle.
    /// Also run when the cmux Live setting changes (``WebDevOverride/setAllowed(_:)``).
    ///
    /// - Parameters:
    ///   - live: Whether the override points pages at a server or an overlay.
    ///   - hosting: The Chromium host (the app's ``PageWebView/chromiumHosting``).
    ///   - pages: The open pages (nil: every live one, ``PageRegistry``).
    ///   - served: The WebKit views the scheme handlers served.
    ///   - watcher: The watcher whose reload count supersedes earlier engine moves (tests pass their own).
    ///   - background: The change came on its own (``WebDevOverride/background``): a page in sight
    ///     never swaps under the eye; it takes the change once it is out of sight (``WebSwapDeferred``).
    ///     An asked change swaps every page at once, in place (``PageWebView/swapReload()``).
    ///   - deferred: Where pages in sight wait for a background change (tests pass their own).
    /// - Returns: The work still running for pages that change engine or swap in place, nil for none (tests wait on it).
    @discardableResult
    static func reloadPages(live: Bool = WebDevOverride.current.isActive,
                            hosting: (any PageChromiumHosting)? = PageWebView.chromiumHosting,
                            pages: [PageWebView]? = nil,
                            served: WebBundleServedViews = .shared,
                            watcher: WebDevOverrideWatcher = .shared,
                            background: Bool = false,
                            deferred: WebSwapDeferred = .shared) -> Task<Void, Never>? {
        watcher.reloadGeneration &+= 1
        let chromiumLive = live && (hosting?.setLivePages(true) ?? false)
        if !live { _ = hosting?.setLivePages(false) }
        let pages = pages ?? PageRegistry.pages()
        // A background change waits out a page in sight (WebSwapGate's sight half, as a web update does).
        let holds = { (page: PageWebView) in background && deferred.inSight(page) }
        let shown = served.shown
        let held = shown.compactMap { view in pages.first { $0.webKitView === view }.flatMap { holds($0) ? $0 : nil } }
        let heldViews = Set(held.map { ObjectIdentifier($0.webKitView) })
        served.reload(shown.filter { !heldViews.contains(ObjectIdentifier($0)) }, to: WebBundleOverlay.shared.activeTree)
        for page in held {
            deferred.hold(page) { page in served.reload([page.webKitView], to: WebBundleOverlay.shared.activeTree) }
        }
        defer { watcher.chromiumServedLive = chromiumLive }
        // The loop is on and this Chromium cannot serve it: its open pages show only their bundled
        // files, so each one the engine policy now puts on WebKit reopens there at once, at its route
        // and scroll (a Settings page open before an overlay install showed none of it until it
        // next opened, cmuxterm-hq#7149 L8).
        if live, !chromiumLive, let hosting {
            let moving = pages.filter(\.isOnChromium)
            guard !moving.isEmpty else { return nil }
            // A later reload supersedes these moves: a page whose scroll read outlasts it stays put.
            let generation = watcher.reloadGeneration
            let current = { generation == watcher.reloadGeneration }
            // task-owner: one move per page, on the main actor; each ends with its page
            let moves = moving.map { page in Task { await page.reopenForLiveOverride(hosting: hosting, isCurrent: current) } }
            return Task { // task-owner: waits for this reload's moves (tests wait on it)
                for move in moves { await move.value }
            }
        }
        // Chromium pages reload when they serve the loop now or did until now.
        guard chromiumLive || watcher.chromiumServedLive else { return nil }
        // Each in place with no visible reload (``PageWebView/swapReload()``).
        // task-owner: one swap per page; each ends with its page's restored frame or its cover limit
        let chromium = pages.filter { $0.chromiumPage != nil }
        for page in chromium where holds(page) {
            // task-owner: one swap when the page leaves sight; it ends with its restored frame or cover limit
            deferred.hold(page) { page in Task { await page.swapReload() } }
        }
        let swaps = chromium.filter { !holds($0) }.map { page in Task { await page.swapReload() } }
        guard !swaps.isEmpty else { return nil }
        return Task { // task-owner: waits for this reload's swaps (tests wait on it)
            for swap in swaps { await swap.value }
        }
    }

    /// Follows the overlay's `manifest.json`, which an install writes after its files.
    private func watchManifest(of overlay: URL?) {
        let manifest = overlay?.appending(path: WebDevOverride.manifestName)
        guard manifest != manifestWatcher?.url else { return }
        manifestWatcher?.stop()
        manifestWatcher = nil
        guard let manifest else { return }
        let watcher = ConfigFileWatcher(url: manifest) { [weak self] in
            Task { @MainActor in self?.requestRead() } // task-owner: one coalesced read per manifest event
        }
        manifestWatcher = watcher
        // Reads once more after arming: an install that wrote the manifest after the last read and
        // before this watch is not missed (an unchanged result is dropped by `update`).
        watcher.start(reportInitialChange: true)
    }
}
