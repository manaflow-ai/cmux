import Foundation
import Observation
import os

/// Per-terminal themes, keyed `<machine>:<tab id>`, in a small app-local
/// file (`<Application Support>/<bundle id>/terminal-themes.json`).
///
/// Room and workspace themes are personal rows in the home daemon
/// (`profiles-v1`); its tables have no per-terminal column, so terminal
/// themes stay on this Mac, like other per-client view state. Entries of
/// terminals that closed are pruned when their machine's tree is loaded.
@MainActor
@Observable
final class TerminalThemeStore {
    private(set) var themes: [String: String] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    /// The file was read; until then a save waits, so it never publishes
    /// a partial set over the saved one.
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var saveAfterLoad = false
    /// The file holds entries this build could not read (a newer format)
    /// or could not be read: it is left as is, and changes stay in memory.
    @ObservationIgnored private var keepsFile = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "themes")

    /// `url` nil keeps themes in memory only (tests). Changes reach the
    /// file once `load()` has read it.
    init(url: URL?) {
        self.url = url
    }

    static func forApplication(bundleIdentifier: String?) -> TerminalThemeStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return TerminalThemeStore(url: support.appending(path: bundle).appending(path: "terminal-themes.json"))
    }

    static func key(machine: String, tab: String) -> String { "\(machine):\(tab)" }

    func theme(for key: String) -> String? { themes[key] }

    /// The themes to move into personal state (`ThemeCoordinator.migrateTerminalThemes`).
    /// None from a kept file: clearing its entries cannot reach the file,
    /// so every launch would migrate them again, over newer picks.
    var migratableThemes: [String: String] { keepsFile ? [:] : themes }

    /// Sets or clears (nil) one terminal's theme.
    func set(_ theme: String?, for key: String) {
        guard themes[key] != theme else { return }
        themes[key] = theme
        save()
    }

    /// Drops themes of `machine`'s terminals that are not in `liveTabs`.
    func prune(machine: String, liveTabs: Set<String>) {
        let prefix = "\(machine):"
        let stale = themes.keys.filter { $0.hasPrefix(prefix) && !liveTabs.contains(String($0.dropFirst(prefix.count))) }
        guard !stale.isEmpty else { return }
        for key in stale { themes[key] = nil }
        save()
    }

    /// Reads the file once at launch, off the main thread.
    func load() async {
        guard let url else { return }
        let logger = logger
        let loaded = await Task.detached(priority: .userInitiated) { Self.read(url, logger: logger) }.value
        // A theme set before the file loaded wins.
        themes = loaded.themes.merging(themes) { _, current in current }
        keepsFile = !loaded.complete
        if keepsFile { logger.error("terminal-themes.json has entries this build cannot read; leaving it unchanged") }
        isLoaded = true
        if saveAfterLoad {
            saveAfterLoad = false
            save()
        }
    }

    /// The string entries of the file at `url`. `complete` is false when
    /// the file is a JSON object some of whose entries are not themes (a
    /// newer format), or could not be read: it is kept. A file that is not
    /// a JSON object at all (a damaged write) is moved aside to
    /// `<name>.corrupt` (`<name>.corrupt-<uuid>` when that exists, never over it) and
    /// reads as empty.
    nonisolated static func read(_ url: URL, logger: Logger) -> (themes: [String: String], complete: Bool) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return ([:], true) }
        // concurrency-allow: called from a detached task in load(), off the main actor
        guard let data = try? Data(contentsOf: url) else { return ([:], false) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let first = url.appendingPathExtension("corrupt")
            let aside = manager.fileExists(atPath: first.path) ? url.appendingPathExtension("corrupt-\(UUID().uuidString)") : first
            do {
                try manager.moveItem(at: url, to: aside)
                logger.error("terminal-themes.json is not JSON; moved it to \(aside.lastPathComponent, privacy: .public)")
                return ([:], true)
            } catch {
                logger.error("terminal-themes.json is not JSON and could not be moved aside: \(String(describing: error), privacy: .public)")
                return ([:], false)
            }
        }
        let themes = object.compactMapValues { $0 as? String }
        return (themes, themes.count == object.count)
    }

    /// Waits for every queued write (tests).
    func flush() async {
        await lastWrite?.value
    }

    private func save() {
        guard let url, !keepsFile else { return }
        guard isLoaded else {
            saveAfterLoad = true
            return
        }
        let data = try? JSONEncoder().encode(themes)
        let empty = themes.isEmpty
        let previous = lastWrite, logger = logger
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                if let data, !empty {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                logger.error("terminal themes write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
