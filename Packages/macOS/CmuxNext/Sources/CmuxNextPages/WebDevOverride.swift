public import Foundation
import CmuxNextCompat
import os

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
///   A surface whose folder or entry is missing there keeps its bundled files. An overlay whose
///   manifest names another `abi` than this app's bundled `pages/web-abi.json` is refused
///   (``refusal``), as a web update is: its pages would call host ops the app lacks.
/// - `gallery`: the live gallery's server (`bun run gallery:dev`, `http://127.0.0.1:4178/` from
///   `scripts/cmux-next/web-dev.sh`), whose stages Gallery Stage (`gallery.openStage`) shows as tabs
///   of this app, in its own theme and backdrop (``GalleryStageTabs``). Pages ignore it.
///
/// A server wins over an overlay for the files it serves. `"enabled": false`, an empty object or
/// a deleted file restores the bundled pages. ``WebDevOverrideWatcher`` keeps ``current`` and
/// reloads every page and agent pane on a change, in WebKit and in Chromium. Every build reads the
/// file (Leo, 2026-11-05: "you should be able to just change your app without going through all
/// this hoopla"); Settings > General > cmux Live (`updates.liveWebReload`, on by default,
/// ``setAllowed(_:)``) turns it off without editing it.
///
/// Recovery, so a layer cannot lock anyone out (Leo, 2026-11-14: "I want people to not accidentally
/// soft lock themselves and like have good recovery options or whatever"): a page or agent pane
/// served from an overlay install that fails to load, ends, or never speaks while shown
/// (``OverlayStartCheck``) refuses that install in memory, once, so every page reloads bundled, and
/// ``WebDevOverrideWatcher/onFallBack`` turns the layer off. `--no-customizations` (``ignoreThisRun()``) serves no layer
/// for one run.
public nonisolated struct WebDevOverride: Sendable, Equatable {
    /// The Vite server pages load from, nil for none.
    public var server: PageDevServer?
    /// The folder of built bundles, nil for none.
    public var overlay: URL?
    /// The overlay's `manifest.json` bytes, so each install is a change.
    public var stamp: Data?
    /// The live gallery's server root, nil for none (Gallery Stage then tries ``defaultGallery``).
    public var gallery: URL?
    /// Why the overlay is not served, nil when it is: its manifest's `abi` (the native interface its
    /// bundles need) is not this app's. The overlay stays watched, so an install that fits is served.
    public var refusal: String?
    /// The change came on its own (`"trigger": "background"`: a layer rebuilt after an app update, a
    /// waiter's swap, an expiry), not from the person asking for it (`"asked"`, the default when the
    /// file names none: `customize use|try|library on|off`, a `cmux live` edit). A page in sight
    /// takes a background change only once it is out of sight (``WebDevOverrideWatcher``).
    public var background = false

    public init(server: PageDevServer? = nil, overlay: URL? = nil, stamp: Data? = nil, gallery: URL? = nil,
                refusal: String? = nil) {
        self.server = server
        self.overlay = overlay
        self.stamp = stamp
        self.gallery = gallery
        self.refusal = refusal
    }

    /// The gallery server `scripts/cmux-next/web-dev.sh` starts by default.
    public static let defaultGallery = URL(string: "http://127.0.0.1:4178/")

    /// Whether pages load from a server or an overlay (an empty override serves the bundle).
    public var isActive: Bool { server != nil || overlay != nil }

    /// Where pages load their files from: the dev server's root and the overlay install, when it is
    /// not refused. Only a change of this reloads pages: a new server token, the gallery, or a refused
    /// overlay's install (a new stamp, or another refusal) leaves every page where it loads from.
    public nonisolated struct Source: Sendable, Equatable {
        public var server: URL?
        public var overlay: URL?
        public var stamp: Data?
    }

    /// What pages are served from now (``Source``).
    public var source: Source {
        refusal == nil ? Source(server: server?.root, overlay: overlay, stamp: stamp) : Source(server: server?.root)
    }

    /// What changed from `before` to `after`, in one line for the log: the dev server (on, off, another
    /// one, a new token), the overlay (on, off, another install, refused or served) and the gallery.
    /// "nothing" when they are the same.
    public static func describeChange(from before: WebDevOverride, to after: WebDevOverride) -> String {
        var parts: [String] = []
        let server = { (value: WebDevOverride) in value.server?.root.absoluteString ?? "off" }
        if before.server?.root != after.server?.root {
            parts.append("server \(server(before)) -> \(server(after))")
        } else if before.server != after.server {
            parts.append("server \(server(after)) new token")
        }
        if overlayChanged(from: before, to: after) {
            let overlay = { (value: WebDevOverride) -> String in
                guard let path = value.overlay?.path else { return "off" }
                return value.refusal.map { "\(path) (refused: \($0))" } ?? path
            }
            let sameFolder = before.overlay == after.overlay
            parts.append(sameFolder && before.refusal == after.refusal
                ? "overlay \(overlay(after)) new install" : "overlay \(overlay(before)) -> \(overlay(after))")
        }
        if before.gallery != after.gallery {
            parts.append("gallery \(before.gallery?.absoluteString ?? "off") -> \(after.gallery?.absoluteString ?? "off")")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }

    /// Whether the overlay itself changed: its folder, its install (stamp) or its refusal.
    public static func overlayChanged(from before: WebDevOverride, to after: WebDevOverride) -> Bool {
        before.overlay != after.overlay || before.stamp != after.stamp || before.refusal != after.refusal
    }

    /// The file's name, next to `cmux-next.json`.
    public static let fileName = "web-dev.json"
    /// The file an overlay install writes last.
    public static let manifestName = "manifest.json"

    /// Whether this build reads `web-dev.json`: every build does. Kept as the one switch the watch,
    /// the projection window and Gallery Stage ask.
    public static let isEnabled = true

    /// One overlay install: its folder and its `manifest.json` bytes (``stamp``). A page that did not
    /// start from it names it (``overlayDidNotStart(_:page:why:)``), so a newer install is tried anew.
    public nonisolated struct OverlayInstall: Sendable, Equatable {
        public var overlay: URL
        public var stamp: Data?

        public init(overlay: URL, stamp: Data?) {
            self.overlay = overlay
            self.stamp = stamp
        }
    }

    /// The install this override serves pages from, nil when it serves none: no overlay, a refused
    /// one, or a server, which wins for the files it serves (its pages are a dev loop, not an install).
    public var servedInstall: OverlayInstall? {
        guard let overlay, refusal == nil, server == nil else { return nil }
        return OverlayInstall(overlay: overlay, stamp: stamp)
    }

    /// What the watcher read from `web-dev.json`, `updates.liveWebReload` (``setAllowed(_:)``), on
    /// until the settings say otherwise, a launch that ignores every layer (``ignoreThisRun()``) and
    /// the install a page did not start from: one lock for all.
    nonisolated struct Held: Sendable {
        var read = WebDevOverride()
        var allowed = true
        var ignoredThisRun = false
        /// The install a page or agent pane did not start from, and why: refused in memory, as an
        /// overlay for another web ABI is, until another install (a new stamp) replaces it.
        var notStarted: (install: OverlayInstall, reason: String)?

        /// The override in force: empty while cmux Live is off or this run ignores layers; the read
        /// one otherwise, refused when its install did not start.
        var inForce: WebDevOverride {
            guard allowed, !ignoredThisRun else { return WebDevOverride() }
            var value = read
            if value.refusal == nil, let notStarted, let overlay = value.overlay,
               notStarted.install == OverlayInstall(overlay: overlay, stamp: value.stamp) {
                value.refusal = notStarted.reason
            }
            return value
        }

        /// Refuses `install` for this run; false when it is not the one served now (it already fell
        /// back, a newer install replaced it, or nothing serves it): one fallback per install.
        mutating func fallBack(from install: OverlayInstall, reason: String) -> Bool {
            guard inForce.servedInstall == install else { return false }
            notStarted = (install, reason)
            return true
        }
    }

    // Lock carve-out: the scheme handlers read the override synchronously off the main actor while
    // the watcher writes it on the main actor; each access is one short copy, never a wait.
    private static let state = Mutex(Held())

    /// Whether cmux Live (`updates.liveWebReload`) lets `web-dev.json` apply, and this run does not
    /// ignore it (``ignoreThisRun()``).
    public static var isAllowed: Bool { state.withLock { $0.allowed && !$0.ignoredThisRun } }

    /// The override in force: what the watcher read from `web-dev.json`, or empty while cmux Live is
    /// off or this run ignores it. An install a page did not start from is refused.
    public static var current: WebDevOverride {
        state.withLock { $0.inForce }
    }

    /// Follows the cmux Live setting (`updates.liveWebReload`): off ignores `web-dev.json`
    /// without editing it. A change reloads every page and agent pane from where it now loads.
    @MainActor public static func setAllowed(_ on: Bool) {
        change { $0.allowed = on }
    }

    /// This run ignores `web-dev.json` whatever cmux Live says, and edits no file: the launch for a
    /// UI that is itself broken (`--no-customizations`, `CMUX_NO_CUSTOMIZATIONS=1`). The next launch
    /// without it serves the layers again.
    @MainActor public static func ignoreThisRun() {
        Logger(subsystem: "com.cmuxterm.app.next", category: "web-dev").notice("this run ignores every customization layer")
        change { $0.ignoredThisRun = true }
    }

    /// A page or agent pane served from `install` did not start (`why`: its load failed, its process
    /// ended, or its page code never answered): every page reloads from the bundle at once, and
    /// ``WebDevOverrideWatcher/onFallBack`` turns the layer off. Once per install; false when nothing changed.
    @MainActor @discardableResult
    public static func overlayDidNotStart(_ install: OverlayInstall, page: String, why: String) -> Bool {
        let reason = "\(page) did not start: \(why)"
        guard state.withLock({ $0.fallBack(from: install, reason: reason) }) else { return false }
        Logger(subsystem: "com.cmuxterm.app.next", category: "web-dev").error("overlay fell back to the bundled pages: \(reason, privacy: .public)")
        WebDevOverrideWatcher.reloadPages(why: "overlay fell back to the bundled pages")
        WebDevOverrideWatcher.shared.onFallBack?(reason)
        return true
    }

    /// Applies `edit` and reloads every page when where pages load from changed (``source``).
    @MainActor private static func change(_ edit: (inout Held) -> Void) {
        let (before, after) = state.withLock { held in
            let before = held.inForce
            edit(&held)
            return (before, held.inForce)
        }
        guard before.source != after.source else { return }
        WebDevOverrideWatcher.reloadPages(why: describeChange(from: before, to: after))
    }

    /// The live gallery's server for Gallery Stage: web-dev.json's `gallery`, else ``defaultGallery``.
    /// Read whatever cmux Live says, since no page loads from it.
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
        value.background = (object["trigger"] as? String) == "background"
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
    /// A missing file is an empty override. `appABI` is the native interface this app's pages need.
    static func read(file: URL, home: URL, appABI: Int? = bundledABI()) -> WebDevOverride {
        guard let data = try? Data(contentsOf: file) else { return WebDevOverride() }
        var value = parse(data, home: home)
        if let overlay = value.overlay {
            value.stamp = try? Data(contentsOf: overlay.appending(path: manifestName))
            value.refusal = value.stamp.flatMap { abiRefusal(manifest: $0, appABI: appABI) }
        }
        return value
    }

    /// The `abi` of this app's bundled `pages/web-abi.json`, nil when it has none.
    static func bundledABI() -> Int? {
        nonisolated struct File: Decodable { var abi: Int }
        guard let pages = WebBundleOverlay.bundledPages,
              let data = try? Data(blockingContentsOf: pages.appending(path: "web-abi.json"))
        else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.abi
    }

    /// Why an overlay with `manifest` is refused by an app whose pages need `appABI`: a manifest that
    /// names another `abi`. An older install names none, and an app with no `web-abi.json` checks
    /// nothing, so both are served as before.
    static func abiRefusal(manifest: Data, appABI: Int?) -> String? {
        nonisolated struct Manifest: Decodable { var abi: Int?; var commit: String? }
        guard let appABI, let read = try? JSONDecoder().decode(Manifest.self, from: manifest),
              let abi = read.abi, abi != appABI
        else { return nil }
        return "the overlay (\(read.commit ?? "unknown commit")) needs web ABI \(abi); this app has \(appABI)"
    }

    /// The overlay folder `relative` (`agent-pane`, `pages/settings`, `webviews-app`) when it holds
    /// `entry`, with symlinks resolved (an install swaps symlinks); else nil.
    public func overlayRoot(_ relative: String, entry: String = "index.html") -> URL? {
        guard let overlay, refusal == nil, !relative.isEmpty,
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
