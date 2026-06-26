import Foundation
import os

nonisolated private let settingsFileReaderLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

/// Reads cmux settings JSON files from disk and projects them into a
/// ``ResolvedSettingsSnapshot``.
///
/// Owns the file-I/O half of settings resolution: it reads the primary
/// `cmux.json` and any fallback files (`settings.json`, the Application Support
/// copy) through an injected `FileManager`, preprocesses JSONC, and decodes the
/// JSON root, then hands each root to a stateless ``SettingsFileParser`` for the
/// section-by-section projection. It performs no apply/backup/restore side
/// effects: ``CmuxSettingsFileStore`` owns that lifecycle and calls
/// ``resolveSettings()`` / ``loadSettings(at:)`` to obtain the parsed snapshot.
struct SettingsFileReader {
    let primaryPath: String
    let fallbackPaths: [String]
    let fileManager: FileManager
    let parser: SettingsFileParser

    init(
        primaryPath: String,
        fallbackPaths: [String],
        fileManager: FileManager,
        parser: SettingsFileParser = SettingsFileParser()
    ) {
        self.primaryPath = primaryPath
        self.fallbackPaths = fallbackPaths
        self.fileManager = fileManager
        self.parser = parser
    }

    func resolveSettings() -> ResolvedSettingsSnapshot {
        switch loadSettings(at: primaryPath) {
        case .parsed(var snapshot):
            mergeFallbackSettings(into: &snapshot)
            return snapshot
        case .invalid:
            return ResolvedSettingsSnapshot(path: primaryPath)
        case .missing:
            break
        }

        var fallbackSnapshot = ResolvedSettingsSnapshot(path: nil)
        mergeFallbackSettings(into: &fallbackSnapshot)
        return fallbackSnapshot
    }

    private func mergeFallbackSettings(into snapshot: inout ResolvedSettingsSnapshot) {
        for fallbackPath in fallbackPaths {
            guard case .parsed(let fallbackSnapshot) = loadSettings(at: fallbackPath) else {
                continue
            }
            snapshot.fillMissingSettings(from: fallbackSnapshot)
        }
    }

    enum LoadResult {
        case missing
        case invalid
        case parsed(ResolvedSettingsSnapshot)
    }

    func loadSettings(at path: String) -> LoadResult {
        guard fileManager.fileExists(atPath: path) else {
            return .missing
        }
        guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
            return .invalid
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
            guard let root = object as? [String: Any] else {
                return .invalid
            }
            return .parsed(parser.parseSettingsFile(root: root, sourcePath: path))
        } catch {
            settingsFileReaderLogger.warning("parse error at \(path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))")
            return .invalid
        }
    }
}
