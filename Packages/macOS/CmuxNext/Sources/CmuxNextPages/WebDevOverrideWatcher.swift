import CmuxNextSettings
public import Foundation
public import WebKit

/// Watches `web-dev.json` and the overlay's `manifest.json` (``WebDevOverride``), keeps
/// ``WebDevOverride/current`` and reloads every web view the page and agent pane scheme handlers
/// served on a change (``WebBundleServedViews``, the one list a web UI update also reloads). Does
/// nothing unless ``WebDevOverride/isEnabled``.
public final class WebDevOverrideWatcher {
    public static let shared = WebDevOverrideWatcher()

    private var fileWatcher: ConfigFileWatcher?
    private var manifestWatcher: ConfigFileWatcher?
    private var file: URL?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var readTask: Task<Void, Never>?
    private var readRequested = false

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
        Self.reloadPages()
    }

    /// Reloads every page and agent pane from where the override now says, in both engines: the
    /// same URL again, which the WebKit scheme handlers and (with ``PageChromiumHosting/setLivePages(_:)``)
    /// Chromium's page host answer from the dev server, the overlay, a web update or the bundle.
    /// Also run when the Live Web Reload setting changes (``WebDevOverride/setAllowed(_:)``).
    ///
    /// - Parameters:
    ///   - live: Whether the override points pages at a server or an overlay.
    ///   - hosting: The Chromium host (the app's ``PageWebView/chromiumHosting``).
    ///   - pages: The open pages (nil: every live one, ``PageRegistry``).
    ///   - served: The WebKit views the scheme handlers served.
    /// - Returns: The work still running for pages that change engine, nil for none (tests wait on it).
    @discardableResult
    static func reloadPages(live: Bool = WebDevOverride.current.isActive,
                            hosting: (any PageChromiumHosting)? = PageWebView.chromiumHosting,
                            pages: [PageWebView]? = nil,
                            served: WebBundleServedViews = .shared) -> Task<Void, Never>? {
        let chromiumLive = live && (hosting?.setLivePages(true) ?? false)
        if !live { _ = hosting?.setLivePages(false) }
        served.reloadServed()
        let pages = pages ?? PageRegistry.pages()
        defer { chromiumServedLive = chromiumLive }
        // The loop is on and this Chromium cannot serve it: its open pages show only their bundled
        // files, so each one the engine policy now puts on WebKit reopens there at once, at its route
        // and scroll (a Settings page open before an overlay install showed none of it until it
        // next opened, cmuxterm-hq#7149 L8).
        if live, !chromiumLive, let hosting {
            let moving = pages.filter(\.isOnChromium)
            guard !moving.isEmpty else { return nil }
            return Task { // task-owner: the engine moves of this reload; each page's own work ends with the page
                await withTaskGroup(of: Void.self) { group in
                    for page in moving { group.addTask { await page.reopenForLiveOverride(hosting: hosting) } }
                }
            }
        }
        // Chromium pages reload when they serve the loop now or did until now.
        guard chromiumLive || chromiumServedLive else { return nil }
        for page in pages where page.chromiumPage != nil { page.reload() }
        return nil
    }

    /// Whether Chromium pages were serving the live loop after the last ``reloadPages()``.
    private static var chromiumServedLive = false

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
