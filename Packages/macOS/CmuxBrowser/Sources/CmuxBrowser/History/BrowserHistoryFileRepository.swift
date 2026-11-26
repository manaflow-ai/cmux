public import Foundation

/// Mediates the on-disk `browser_history.json` snapshot: synchronous first-load
/// decode, atomic debounced persist, legacy-file migration, and delete-on-clear.
///
/// All filesystem access goes through an injected `FileManager`, and the JSON
/// shape is fixed (`JSONEncoder` with `.withoutEscapingSlashes`, plain
/// `JSONDecoder`) so snapshots stay wire-compatible with files written by the
/// pre-package store. The static ``persist(_:to:)`` helper captures no instance
/// state, so the store's detached debounce task can write a snapshot without
/// touching this repository (which is `@MainActor`-owned, not `Sendable`, since
/// it holds a `FileManager`).
public struct BrowserHistoryFileRepository {
    private let fileManager: FileManager

    /// Creates a repository over `fileManager` (inject a scoped manager in
    /// tests; pass `.default` at the app composition root).
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Decodes the persisted snapshot at `fileURL`, returning `nil` when the
    /// file is missing or cannot be decoded (the store then starts empty,
    /// matching the prior silent-failure behavior).
    public func loadSnapshot(from fileURL: URL) -> [BrowserHistoryEntry]? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return nil
        }
        do {
            return try JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        } catch {
            return nil
        }
    }

    /// Copies a legacy raw-bundle-identifier history file to `targetURL` when
    /// the target does not yet exist and a distinct legacy file is present.
    /// Best-effort: any error leaves the target absent so first-load starts
    /// empty.
    public func migrateLegacyFileIfNeeded(legacyURL: URL?, to targetURL: URL) {
        guard !fileManager.fileExists(atPath: targetURL.path) else { return }
        guard let legacyURL,
              legacyURL != targetURL,
              fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }
        do {
            let dir = targetURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.copyItem(at: legacyURL, to: targetURL)
        } catch {
            return
        }
    }

    /// Removes the persisted history file at `fileURL`, ignoring errors (a
    /// missing file is already the cleared state).
    public func removeFile(at fileURL: URL) {
        try? fileManager.removeItem(at: fileURL)
    }

    /// Atomically writes `snapshot` to `fileURL`, creating the parent directory.
    /// Uses `JSONEncoder` with `.withoutEscapingSlashes` to keep the on-disk
    /// JSON byte-identical to prior builds. Static + `Sendable` so the store's
    /// detached debounce task can call it directly with a captured snapshot.
    public static func persist(_ snapshot: [BrowserHistoryEntry], to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}
