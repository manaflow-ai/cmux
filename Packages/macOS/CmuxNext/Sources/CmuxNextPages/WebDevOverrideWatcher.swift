import CmuxNextSettings
public import Foundation
import os
public import WebKit

/// Watches `web-dev.json` and the overlay's `manifest.json` (``WebDevOverride``), keeps
/// ``WebDevOverride/current`` and reloads every web view the page and agent pane scheme handlers
/// served on a change (``WebBundleServedViews``, the one list a web UI update also reloads). Does
/// nothing unless ``WebDevOverride/isEnabled``.
public final class WebDevOverrideWatcher {
    // lint:allow singleton - the app has one web-dev.json and one set of served views; tests pass their own
    // watcher to reloadPages(watcher:).
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
    /// Reloads each Chromium page at its safe point, under a picture of itself.
    let pageReload = PageGracefulReload()
    /// Reloads the served views each at its own safe point (``reloadPages(live:hosting:pages:served:watcher:)``).
    let gracefulReload = WebBundleGracefulReload()

    /// Told each time ``WebDevOverride/current`` changes (``whenChanged(_:)``).
    private var changed: [@MainActor () -> Void] = []

    /// Calls `body` each time ``WebDevOverride/current`` changes: a pull request's pages came on or went
    /// off (``CustomizeExperiments``). Starts the watch, so the first read happens now.
    func whenChanged(_ body: @escaping @MainActor () -> Void) {
        changed.append(body)
        start()
    }

    /// A Customization Library change ran (``SettingsCustomizeLibrary``): it can turn a pull request's
    /// pages off without moving ``WebDevOverride/current`` (a lower PR of two), so the followers read again.
    func libraryChanged() {
        for body in changed { body() }
    }

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
        let before = WebDevOverride.current
        guard WebDevOverride.update(value) else { return }
        for body in changed { body() }
        let after = WebDevOverride.current
        let change = WebDevOverride.describeChange(from: before, to: after)
        // Only a change of the overlay itself is its refusal's news: on 2026-11-22 06:41:33Z a dev server
        // turned on, every page reloaded, and the one line logged was the unchanged overlay's refusal.
        if let refusal = after.refusal, WebDevOverride.overlayChanged(from: before, to: after) {
            Self.log.notice("overlay refused: \(refusal, privacy: .public)")
        }
        // A file write that leaves every page where it loads from (a new token, the gallery, a refused
        // install) reloads nothing: each reload blanks every chat until its document loads again.
        guard before.source != after.source else {
            Self.log.notice("web-dev.json changed (\(change, privacy: .public)); pages load from the same place, nothing reloaded")
            return
        }
        Self.reloadPages(why: "web-dev.json: \(change)")
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "web-dev")

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
    ///   - why: What changed, for the log line that counts the views reloaded.
    /// - Returns: The work still running for pages that change engine or reload in Chromium, nil for none (tests wait on it).
    @discardableResult
    static func reloadPages(live: Bool = WebDevOverride.current.isActive,
                            hosting: (any PageChromiumHosting)? = PageWebView.chromiumHosting,
                            pages: [PageWebView]? = nil,
                            served: WebBundleServedViews = .shared,
                            watcher: WebDevOverrideWatcher = .shared,
                            why: String = "web source changed") -> Task<Void, Never>? {
        watcher.reloadGeneration &+= 1
        let chromiumLive = live && (hosting?.setLivePages(true) ?? false)
        if !live { _ = hosting?.setLivePages(false) }
        // Each served view reloads at its own safe point under a picture of itself, keeping the
        // composer's draft and keyboard (``WebBundleGracefulReload``), not all of them blank at once.
        let shown = served.shown
        watcher.gracefulReload.reload(shown, to: WebBundleOverlay.shared.activeTree, served: served)
        let webKit = shown.count
        let pages = pages ?? PageRegistry.pages()
        // The counts of what follows: pages that move to WebKit, or Chromium pages that reload.
        let moves = live && !chromiumLive && hosting != nil
        let moving = moves ? pages.filter(\.isOnChromium).count : 0
        let chromium = !moves && (chromiumLive || watcher.chromiumServedLive) ? pages.filter { $0.chromiumPage != nil }.count : 0
        log.notice("\(why, privacy: .public): reloading \(webKit) WebKit views, \(chromium) Chromium pages, moving \(moving) to WebKit")
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
        // Chromium pages reload when they serve the loop now or did until now, each at its safe point
        // under a picture of itself (``PageGracefulReload``), as the WebKit views do.
        guard chromiumLive || watcher.chromiumServedLive else { return nil }
        return watcher.pageReload.reload(pages.filter { $0.chromiumPage != nil })
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
