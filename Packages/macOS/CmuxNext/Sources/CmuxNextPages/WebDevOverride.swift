public import Foundation
import CmuxNextCompat

/// The live web loop of a Debug, NIGHTLY or cmux NEXT DEV app (plans/cmux-next/web-live-reload.md): `web-dev.json`
/// next to `cmux-next.json` points the app's web surfaces at a loopback Vite server (hot reload)
/// or at an overlay folder of built bundles, with no app build and no relaunch.
///
/// ```json
/// {"server": "http://127.0.0.1:4181/", "overlay": "~/Library/Application Support/cmux-next/web-overlay"}
/// ```
///
/// - `server`: the React pages and viewers (``PageDevServer``, the same paths `bun run dev`
///   serves) and the agent pane (`/agent-pane/`) load their files from it and keep their own
///   origins, so the host bridge and trust stay the shipped ones. A request the server cannot
///   answer falls back to the bundled file, so a stopped server leaves the bundled pages.
/// - `overlay`: built bundles in `pages/<resource>/`, `agent-pane/` and `webviews-app/`
///   (`scripts/cmux-next/web-overlay.sh install` swaps them in and then writes `manifest.json`).
///   A surface whose folder or entry is missing there keeps its bundled files.
///
/// A server wins over an overlay for the files it serves. `"enabled": false`, an empty object or
/// a deleted file restores the bundled pages. ``WebDevOverrideWatcher`` keeps ``current`` and
/// reloads every page and agent pane on a change. Release and RC builds never read the file:
/// ``isEnabled`` follows ``isAvailable`` (a Debug compile, a nightly bundle or cmux NEXT DEV).
public nonisolated struct WebDevOverride: Sendable, Equatable {
    /// The Vite server pages load from, nil for none.
    public var server: PageDevServer?
    /// The folder of built bundles, nil for none.
    public var overlay: URL?
    /// The overlay's `manifest.json` bytes, so each install is a change.
    public var stamp: Data?

    public init(server: PageDevServer? = nil, overlay: URL? = nil, stamp: Data? = nil) {
        self.server = server
        self.overlay = overlay
        self.stamp = stamp
    }

    /// Whether pages load from a server or an overlay (an empty override serves the bundle).
    public var isActive: Bool { server != nil || overlay != nil }

    /// The file's name, next to `cmux-next.json`.
    public static let fileName = "web-dev.json"
    /// The file an overlay install writes last.
    public static let manifestName = "manifest.json"

    /// Whether `web-dev.json` is read at all: a Debug compile, a nightly bundle (tagged or not), or
    /// cmux NEXT DEV, the daily dogfood build (a Release compile with its own id). The rule of
    /// `DevTools.isAvailable` (CmuxNextActions, which this module does not use), plus that build.
    public static func isAvailable(bundleID: String?, isDebugBuild: Bool) -> Bool {
        if isDebugBuild { return true }
        guard let bundle = bundleID?.trimmingCharacters(in: .whitespaces) else { return false }
        let nightly = "com.cmuxterm.app.nightly"
        return bundle == nightly || bundle.hasPrefix(nightly + ".") || bundle == nextDevBundleID
    }

    /// cmux NEXT DEV's bundle id (docs/cmux-next/dev-daily.md).
    static let nextDevBundleID = "com.cmuxterm.app.debug.next"

    /// This process: decided once from its own bundle.
    public static let isEnabled: Bool = {
        #if DEBUG
        isAvailable(bundleID: Bundle.main.bundleIdentifier, isDebugBuild: true)
        #else
        isAvailable(bundleID: Bundle.main.bundleIdentifier, isDebugBuild: false)
        #endif
    }()

    private static let state = Mutex(WebDevOverride())

    /// The override in force: empty unless ``isEnabled``, the watcher read a file and the Debug
    /// Settings toggle (``PageTunables/webDevOverride``) is on.
    public static var current: WebDevOverride {
        guard PageTunables.webDevOverride.value else { return WebDevOverride() }
        return state.withLock { $0 }
    }

    /// Replaces ``current``; returns whether it changed. Ignored unless ``isEnabled``.
    @discardableResult
    static func update(_ value: WebDevOverride) -> Bool {
        guard isEnabled else { return false }
        return state.withLock { held in
            guard held != value else { return false }
            held = value
            return true
        }
    }

    /// The override `data` (the file's bytes) describes: nil fields for a missing or invalid
    /// value, an empty override for invalid JSON or `"enabled": false`. `server` must pass
    /// ``PageDevServer/loopbackURL(_:)``; `overlay` is an absolute path or one under `~`.
    public static func parse(_ data: Data, home: URL) -> WebDevOverride {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["enabled"] as? Bool) ?? true
        else { return WebDevOverride() }
        var value = WebDevOverride()
        if let server = object["server"] as? String, let root = PageDevServer.loopbackURL(server) {
            value.server = PageDevServer(root: root)
        }
        if let overlay = object["overlay"] as? String, let url = overlayURL(overlay, home: home) {
            value.overlay = url
        }
        return value
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
