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
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "themes")

    /// `url` nil keeps themes in memory only (tests).
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
        let loaded = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            // concurrency-allow: runs in a detached task, off the main actor
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }.value
        // A theme set before the file loaded wins.
        themes = loaded.merging(themes) { _, current in current }
    }

    private func save() {
        guard let url else { return }
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
