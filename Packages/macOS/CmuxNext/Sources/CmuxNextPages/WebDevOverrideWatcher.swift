import CmuxNextSettings
public import Foundation

/// Watches `web-dev.json` and the overlay's `manifest.json` (``WebDevOverride``), keeps
/// ``WebDevOverride/current`` and, on a change, calls ``onChange``: its ``WebUIHost`` reloads the
/// pages that show and marks the others to reload when they show (``WebUIHost/webBundleDidChange()``),
/// the same path a web UI update takes. Does nothing unless ``WebDevOverride/isEnabled``.
///
/// The host owns the one watcher (``WebUIHost/devOverride``); the first page made starts it, through
/// ``WebUIHost/open(_:)`` or the page host pool's spare (``PageHostPool/willServe``), so a launch that
/// shows no page reads nothing (the first page loads bundled and reloads once the file is read).
public final class WebDevOverrideWatcher {
    private var fileWatcher: ConfigFileWatcher?
    private var manifestWatcher: ConfigFileWatcher?
    private var file: URL?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var readTask: Task<Void, Never>?
    private var readRequested = false
    /// The override changed: the served pages take it.
    var onChange: @MainActor () -> Void

    /// - Parameter onChange: Called after each change of ``WebDevOverride/current``.
    public init(onChange: @escaping @MainActor () -> Void = {}) {
        self.onChange = onChange
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
        // The same URL again: the scheme handler answers it from where the override now says.
        onChange()
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
