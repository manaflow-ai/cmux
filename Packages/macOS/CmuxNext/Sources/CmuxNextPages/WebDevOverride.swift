public import Foundation
import CmuxNextCompat

/// The live web loop of every cmux NEXT build (plans/cmux-next/web-live-reload.md): `web-dev.json`
/// next to `cmux-next.json` points the app's web surfaces at a loopback Vite server (hot reload)
/// or at an overlay folder of built bundles, with no app build and no relaunch.
///
/// ```json
/// {"server": "http://127.0.0.1:4200/", "token": "<48 hex>", "overlay": "~/Library/Application Support/cmux-next/web-overlay"}
/// ```
///
/// - `server`: the React pages and viewers (``PageDevServer``, the same paths `bun run dev`
///   serves) and the agent pane (`/agent-pane/`) load their files from it and keep their own
///   origins, so the host bridge and trust stay the shipped ones. A request the server cannot
///   answer falls back to the bundled file, so a stopped server leaves the bundled pages.
///   `token` is required with it: only answers carrying it (``PageDevServer/token``) are the
///   server's, so a process that takes over the port of a stopped server serves nothing.
/// - `overlay`: built bundles in `pages/<resource>/`, `agent-pane/` and `webviews-app/`
///   (`scripts/cmux-next/web-overlay.sh install` swaps them in and then writes `manifest.json`).
///   A surface whose folder or entry is missing there keeps its bundled files.
/// - `gallery`: the live gallery's server (`bun run gallery:dev`, `http://127.0.0.1:4178/` from
///   `scripts/cmux-next/web-dev.sh`), whose stages Gallery Stage (`gallery.openStage`) shows as tabs
///   of this app, in its own theme and backdrop (``GalleryStageTabs``). Pages ignore it.
///
/// A server wins over an overlay for the files it serves. `"enabled": false`, an empty object or
/// a deleted file restores the bundled pages. ``WebDevOverrideWatcher`` keeps ``current`` and
/// reloads every page and agent pane on a change, in WebKit and in Chromium. Every build reads the
/// file (Leo, 2026-11-05: "you should be able to just change your app without going through all
/// this hoopla"); Settings > General > Live Web Reload (`updates.liveWebReload`, on by default,
/// ``setAllowed(_:)``) turns it off without editing it.
public nonisolated struct WebDevOverride: Sendable, Equatable {
    /// The Vite server pages load from, nil for none.
    public var server: PageDevServer?
    /// The folder of built bundles, nil for none.
    public var overlay: URL?
    /// The overlay's `manifest.json` bytes, so each install is a change.
    public var stamp: Data?
    /// The live gallery's server root, nil for none (Gallery Stage then tries ``defaultGallery``).
    public var gallery: URL?

    public init(server: PageDevServer? = nil, overlay: URL? = nil, stamp: Data? = nil, gallery: URL? = nil) {
        self.server = server
        self.overlay = overlay
        self.stamp = stamp
        self.gallery = gallery
    }

    /// The gallery server `scripts/cmux-next/web-dev.sh` starts by default.
    public static let defaultGallery = URL(string: "http://127.0.0.1:4178/")

    /// Whether pages load from a server or an overlay (an empty override serves the bundle).
    public var isActive: Bool { server != nil || overlay != nil }

    /// The file's name, next to `cmux-next.json`.
    public static let fileName = "web-dev.json"
    /// The file an overlay install writes last.
    public static let manifestName = "manifest.json"

    /// Whether this build reads `web-dev.json`: every build does. Kept as the one switch the watch,
    /// the projection window and Gallery Stage ask.
    public static let isEnabled = true

    /// What the watcher read from `web-dev.json`, and `updates.liveWebReload` (``setAllowed(_:)``),
    /// on until the settings say otherwise: one lock for both.
    private nonisolated struct Held: Sendable {
        var read = WebDevOverride()
        var allowed = true
    }

    private static let state = Mutex(Held())

    /// The override in force: what the watcher read from `web-dev.json`, or empty while
    /// Live Web Reload is off.
    public static var current: WebDevOverride {
        state.withLock { $0.allowed ? $0.read : WebDevOverride() }
    }

    /// Follows the Live Web Reload setting (`updates.liveWebReload`): off ignores `web-dev.json`
    /// without editing it. A change reloads every page and agent pane from where it now loads.
    @MainActor public static func setAllowed(_ on: Bool) {
        let reload = state.withLock { held in
            guard held.allowed != on else { return false }
            held.allowed = on
            return held.read.isActive
        }
        if reload { WebDevOverrideWatcher.reloadPages() }
    }

    /// The live gallery's server for Gallery Stage: web-dev.json's `gallery`, else ``defaultGallery``.
    /// Read whatever Live Web Reload says, since no page loads from it.
    public static var galleryServer: URL? { state.withLock { $0.read.gallery } ?? defaultGallery }

    /// Replaces ``current``; returns whether it changed. Ignored unless ``isEnabled``.
    @discardableResult
    static func update(_ value: WebDevOverride) -> Bool {
        guard isEnabled else { return false }
        return state.withLock { held in
            guard held.read != value else { return false }
            held.read = value
            return true
        }
    }

    /// The override `data` (the file's bytes) describes: nil fields for a missing or invalid
    /// value, an empty override for invalid JSON or `"enabled": false`. `server` and `gallery` must pass
    /// ``PageDevServer/loopbackURL(_:)``; `overlay` is an absolute path or one under `~`.
    public static func parse(_ data: Data, home: URL) -> WebDevOverride {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["enabled"] as? Bool) ?? true
        else { return WebDevOverride() }
        var value = WebDevOverride()
        // A server without its token is ignored: any local process could hold a port a stale file
        // names (``PageDevServer/token``). `web-overlay.sh` writes one.
        if let server = object["server"] as? String, let root = PageDevServer.loopbackURL(server),
           let token = (object["token"] as? String).flatMap(validToken) {
            value.server = PageDevServer(root: root, token: token)
        }
        if let overlay = object["overlay"] as? String, let url = overlayURL(overlay, home: home) {
            value.overlay = url
        }
        if let gallery = object["gallery"] as? String { value.gallery = PageDevServer.loopbackURL(gallery) }
        return value
    }

    /// `raw` as a dev server token: at least 32 characters of `[A-Za-z0-9_-]`, else nil.
    static func validToken(_ raw: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return raw.count >= 32 && raw.allSatisfy(allowed.contains) ? raw : nil
    }

    /// `path` as a folder: `~/x` under `home`, an absolute path as is, else nil.
    static func overlayURL(_ path: String, home: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home.appending(path: String(trimmed.dropFirst(2)), directoryHint: .isDirectory) }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Reads `file` and the overlay's manifest (blocking file reads: call it off the main actor).
    /// A missing file is an empty override.
    static func read(file: URL, home: URL) -> WebDevOverride {
        guard let data = try? Data(contentsOf: file) else { return WebDevOverride() }
        var value = parse(data, home: home)
        if let overlay = value.overlay {
            value.stamp = try? Data(contentsOf: overlay.appending(path: manifestName))
        }
        return value
    }

    /// The overlay folder `relative` (`agent-pane`, `pages/settings`, `webviews-app`) when it holds
    /// `entry`, with symlinks resolved (an install swaps symlinks); else nil.
    public func overlayRoot(_ relative: String, entry: String = "index.html") -> URL? {
        guard let overlay, !relative.isEmpty,
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else { return nil }
        let root = overlay.appending(path: relative, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.appending(path: entry).path) else { return nil }
        return root
    }

    /// The overlay folder of `page`, served from `root` when bundled: `pages/<resource>` for a page
    /// of this module's bundle, else the bundled folder's own name (`webviews-app`, `agent-pane`).
    func overlayRoot(for page: PageDescriptor, bundledRoot root: URL) -> URL? {
        guard overlay != nil else { return nil }
        let inPagesBundle = Bundle.module.url(forResource: page.resource, withExtension: nil, subdirectory: "pages") != nil
        let relative = inPagesBundle ? "pages/\(page.resource)" : root.lastPathComponent
        return overlayRoot(relative, entry: page.entry)
    }
}
