import Foundation

/// Persists the user's diff viewer display preferences (layout plus the
/// options-menu toggles) as a single JSON file shared with the `cmux` CLI.
///
/// The viewer webview saves changes through `DiffCommentsBridge`
/// (`viewerPrefs.set`) and reads them back at boot (`viewerPrefs.get`); the
/// CLI reads the same file when generating a viewer page so new diff panels
/// open with the last-used layout. One file, one source of truth — page-local
/// `localStorage` is only a fallback for pages opened outside cmux, because
/// generated viewer origins do not reliably persist web storage.
final class DiffViewerPreferencesStore: @unchecked Sendable {
    static let shared = DiffViewerPreferencesStore()

    static let validLayouts: Set<String> = ["split", "unified"]
    static let validDiffIndicators: Set<String> = ["bars", "classic", "none"]
    static let booleanKeys: Set<String> = [
        "wordWrap", "wordDiffs", "lineNumbers", "showBackgrounds", "expandUnchanged",
    ]

    private let lock = NSLock()
    private let fileURL: URL?
    private var cached: [String: Any]?

    init(fileURL: URL? = DiffViewerPreferencesStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests, let appSupportDirectory else { return nil }
        return appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
            .appendingPathComponent("preferences.json", isDirectory: false)
    }

    /// Current sanitized preferences. Unknown keys and invalid values are
    /// dropped so corrupt or hand-edited files can never poison the viewer.
    func preferences() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// Merges validated updates into the stored preferences and persists
    /// atomically. Returns the merged result.
    @discardableResult
    func merge(_ updates: [String: Any]) -> [String: Any] {
        let sanitizedUpdates = Self.sanitize(updates)
        lock.lock()
        defer { lock.unlock() }
        var merged = loadLocked()
        for (key, value) in sanitizedUpdates {
            merged[key] = value
        }
        cached = merged
        persistLocked(merged)
        return merged
    }

    static func sanitize(_ raw: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        if let layout = raw["layout"] as? String, validLayouts.contains(layout) {
            sanitized["layout"] = layout
        }
        if let indicators = raw["diffIndicators"] as? String, validDiffIndicators.contains(indicators) {
            sanitized["diffIndicators"] = indicators
        }
        for key in booleanKeys {
            if let value = raw[key] as? Bool {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    private func loadLocked() -> [String: Any] {
        if let cached {
            return cached
        }
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cached = [:]
            return [:]
        }
        let sanitized = Self.sanitize(object)
        cached = sanitized
        return sanitized
    }

    private func persistLocked(_ preferences: [String: Any]) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: preferences,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Preferences are a convenience; losing a write must never break
            // the viewer or the bridge reply.
        }
    }
}
