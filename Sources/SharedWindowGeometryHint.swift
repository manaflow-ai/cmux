import Foundation
import os

nonisolated private let sharedWindowGeometryHintLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "SharedWindowGeometryHint"
)

struct SharedWindowGeometryHint: Codable, Sendable {
    let version: Int
    let updatedAt: TimeInterval
    let writerBundleIdentifier: String
    let frame: SessionRectSnapshot
    let display: SessionDisplaySnapshot?
}

enum SharedWindowGeometryHintStore {
    static let schemaVersion = 1
    private static let defaultBundleIdentifier = "com.cmuxterm.app"

    static func load(fileURL: URL? = nil) -> SharedWindowGeometryHint? {
        guard let fileURL = fileURL ?? defaultFileURL() else { return nil }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        guard let hint = try? JSONDecoder().decode(SharedWindowGeometryHint.self, from: data) else { return nil }
        guard hint.version == schemaVersion else { return nil }
        return hint
    }

    @discardableResult
    static func save(
        from snapshot: AppSessionSnapshot,
        fileURL: URL? = nil,
        writerBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard let primaryWindow = snapshot.windows.first else { return false }
        guard let frame = primaryWindow.frame else { return false }
        return save(
            frame: frame,
            display: primaryWindow.display,
            fileURL: fileURL,
            writerBundleIdentifier: writerBundleIdentifier,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    static func save(
        frame: SessionRectSnapshot,
        display: SessionDisplaySnapshot?,
        fileURL: URL? = nil,
        writerBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        let hint = SharedWindowGeometryHint(
            version: schemaVersion,
            updatedAt: updatedAt,
            writerBundleIdentifier: normalizedBundleIdentifier(writerBundleIdentifier),
            frame: frame,
            display: display
        )
        return save(hint, fileURL: fileURL)
    }

    @discardableResult
    static func save(_ hint: SharedWindowGeometryHint, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(hint)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            sharedWindowGeometryHintLogger.warning(
                "Failed to write shared window geometry hint to \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func defaultFileURL(appSupportDirectory: URL? = nil) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }

        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("window-geometry-hint.json", isDirectory: false)
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String {
        if let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return defaultBundleIdentifier
    }
}
