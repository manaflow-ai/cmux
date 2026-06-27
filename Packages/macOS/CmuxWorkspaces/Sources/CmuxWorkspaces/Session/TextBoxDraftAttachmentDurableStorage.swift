public import Foundation

/// Pure file-system primitives for the textbox draft-attachment durable store.
///
/// Drafts of textbox attachments live in temporary image files that the
/// pasteboard owns. To survive an app relaunch (termination / update restart)
/// the draft snapshot needs a copy outside that temporary directory. This value
/// type owns the leaf storage math: where the durable copy lives, how to derive
/// a stable per-source filename, and the link/copy primitives that materialize
/// it. It holds no draft state (the copy-state machine and pasteboard checks
/// stay app-side); it is a stateless transform over `FileManager` and `URL`,
/// constructed inline at each call site.
public struct TextBoxDraftAttachmentDurableStorage: Sendable {
    private static let directoryName = "textbox-draft-attachments"

    // Justification: FileManager is documented thread-safe ("the methods of
    // the shared FileManager object can be called from multiple threads
    // safely") but Foundation does not mark it Sendable.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a durable-storage helper.
    ///
    /// - Parameter fileManager: File system access, injected for testability.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies a source file into durable storage, returning the durable URL.
    ///
    /// Returns the existing durable URL when the copy already exists, and `nil`
    /// when no durable location can be derived or the copy fails without an
    /// already-present destination.
    public func copyToDurableStorage(_ sourceURL: URL) -> URL? {
        let sourceURL = sourceURL.standardizedFileURL
        guard let destinationURL = durableStorageURL(for: sourceURL) else { return nil }
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL.standardizedFileURL
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL.standardizedFileURL
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                return destinationURL.standardizedFileURL
            }
            return nil
        }
    }

    /// Hard-links a source file into durable storage when the file system allows
    /// it, returning the durable URL or `nil` to fall back to a copy.
    public func linkToDurableStorageIfPossible(_ sourceURL: URL) -> URL? {
        let sourceURL = sourceURL.standardizedFileURL
        guard let destinationURL = durableStorageURL(for: sourceURL) else { return nil }
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        do {
            try fileManager.linkItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                return destinationURL
            }
            return nil
        }
    }

    /// Resolves the durable URL a source file maps to, or `nil` when the storage
    /// directory cannot be created.
    public func durableStorageURL(for sourceURL: URL) -> URL? {
        guard let directory = storageDirectory() else { return nil }
        let sourceURL = sourceURL.standardizedFileURL
        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathToken = stablePathToken(sourceURL.path)
        let fallbackName = fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"
        let filename = "\(pathToken)-\(sourceURL.lastPathComponent.isEmpty ? fallbackName : sourceURL.lastPathComponent)"
        return directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
    }

    /// Returns whether a file URL belongs to this app-owned durable store.
    public func isOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard let directory = storageDirectory(createIfMissing: false) else { return false }
        let directoryPath = directory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    /// Derives a stable FNV-1a token for a source path so equal paths map to the
    /// same durable filename.
    private func stablePathToken(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Resolves the Application Support directory backing the durable store,
    /// optionally creating it.
    private func storageDirectory(createIfMissing: Bool = true) -> URL? {
        guard let appSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        if createIfMissing {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
}
