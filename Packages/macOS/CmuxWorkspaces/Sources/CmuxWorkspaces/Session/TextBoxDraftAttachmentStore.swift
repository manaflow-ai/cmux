public import Foundation
import os

/// Owns the durable on-disk copies of text-box draft attachments so a draft can
/// survive an app relaunch even when its original lives in a Ghostty-owned
/// temporary directory that the OS may reap.
///
/// Faithful lift of the app-target `TextBoxDraftAttachmentStorage` namespace's
/// path/URL-based state machine. Only the file-management half moves here; the
/// app-side `TextBoxAttachment`/`SessionTextBoxInputAttachmentSnapshot`-typed
/// wrappers (which gate on `GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile`
/// and build the app's snapshot type) stay app-side and call this store.
///
/// Lock-guarded synchronous state is deliberate, not a candidate for an actor:
/// ``flushPendingCopiesSynchronously()`` is a synchronous contract driven from
/// termination/update-relaunch saves on the main thread, so the tiny
/// copied/pending/cancelled path bookkeeping is a published value read by
/// synchronous code (`OSAllocatedUnfairLock`), while the only off-main work is a
/// `Task.detached` durable copy. A single process-wide instance backs the live
/// app's draft directory.
public final class TextBoxDraftAttachmentStore: Sendable {
    private let directoryName = "textbox-draft-attachments"

    /// The copied/pending/cancelled bookkeeping guarded by ``draftCopyState``.
    private struct DraftCopyState {
        var copiedDraftPathByOriginalPath: [String: String] = [:]
        var pendingOriginalPaths: Set<String> = []
        var cancelledOriginalPaths: Set<String> = []
    }

    private let draftCopyState = OSAllocatedUnfairLock(
        initialState: DraftCopyState()
    )

    /// Creates a draft-attachment store rooted at the app-support draft directory.
    public init() {}

    /// Begins (or no-ops on an in-flight) durable copy of the original temporary
    /// file, hard-linking when the source and destination share a volume and
    /// falling back to an async copy otherwise.
    public func prepareDurableCopy(forTemporaryFileAtPath originalPath: String) {
        let originalPath = URL(fileURLWithPath: originalPath).standardizedFileURL.path
        let shouldStart = draftCopyState.withLock { state in
            guard state.copiedDraftPathByOriginalPath[originalPath] == nil,
                  !state.pendingOriginalPaths.contains(originalPath),
                  !state.cancelledOriginalPaths.contains(originalPath) else {
                return false
            }
            state.pendingOriginalPaths.insert(originalPath)
            return true
        }
        guard shouldStart else { return }

        let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
        if let durableURL = linkToDurableStorageIfPossible(originalURL) {
            draftCopyState.withLock { state in
                state.pendingOriginalPaths.remove(originalPath)
                state.cancelledOriginalPaths.remove(originalPath)
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
            }
            return
        }

        Task.detached(priority: .utility) {
            let durableURL = self.copyToDurableStorage(originalURL)
            let copiedPathToRemove = self.draftCopyState.withLock { state -> String? in
                guard state.pendingOriginalPaths.remove(originalPath) != nil else {
                    return nil
                }
                guard let durableURL else { return nil }
                if state.cancelledOriginalPaths.remove(originalPath) != nil {
                    return durableURL.path
                }
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
                return nil
            }
            if let copiedPathToRemove {
                try? FileManager.default.removeItem(atPath: copiedPathToRemove)
            }
        }
    }

    /// Flushes every pending durable copy on the calling thread so a
    /// termination/update-relaunch save sees a durable path before it builds the
    /// session snapshot.
    public func flushPendingCopiesSynchronously() {
        let pendingOriginalPaths = draftCopyState.withLock { state in
            Array(state.pendingOriginalPaths)
        }
        for originalPath in pendingOriginalPaths {
            let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
            let durableURL = linkToDurableStorageIfPossible(originalURL)
                ?? copyToDurableStorage(originalURL)
            let copiedPathToRemove = draftCopyState.withLock { state -> String? in
                guard state.pendingOriginalPaths.remove(originalPath) != nil else {
                    return nil
                }
                guard let durableURL else { return nil }
                if state.cancelledOriginalPaths.remove(originalPath) != nil {
                    return durableURL.path
                }
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
                return nil
            }
            if let copiedPathToRemove {
                try? FileManager.default.removeItem(atPath: copiedPathToRemove)
            }
        }
    }

    /// Returns the durable copy URL for an original temporary file if one exists
    /// on disk, pruning the bookkeeping entry when the copy has vanished.
    public func copiedDraftURL(forOriginalURL originalURL: URL) -> URL? {
        let copiedPath = draftCopyState.withLock { state in
            state.copiedDraftPathByOriginalPath[originalURL.standardizedFileURL.path]
        }
        guard let copiedPath else { return nil }
        let copiedURL = URL(fileURLWithPath: copiedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: copiedURL.path) else {
            _ = draftCopyState.withLock { state in
                state.copiedDraftPathByOriginalPath.removeValue(
                    forKey: originalURL.standardizedFileURL.path
                )
            }
            return nil
        }
        return copiedURL
    }

    /// Drops the durable copy tracked for an original temporary file, marking an
    /// in-flight copy for deletion once it finishes.
    public func removeCopiedDraftForOriginalTemporaryFile(_ fileURL: URL) {
        let originalPath = fileURL.standardizedFileURL.path
        let copiedPath = draftCopyState.withLock { state in
            if state.pendingOriginalPaths.contains(originalPath) || state.cancelledOriginalPaths.contains(originalPath) {
                state.cancelledOriginalPaths.insert(originalPath)
            } else {
                state.cancelledOriginalPaths.remove(originalPath)
            }
            return state.copiedDraftPathByOriginalPath.removeValue(forKey: originalPath)
        }
        guard let copiedPath else { return }
        try? FileManager.default.removeItem(atPath: copiedPath)
    }

    /// Removes the file if it is one of this store's durable draft copies,
    /// returning whether it was owned (and thus removed).
    public func removeIfOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard isOwnedDraftCopy(fileURL) else { return false }
        try? FileManager.default.removeItem(at: fileURL.standardizedFileURL)
        return true
    }

    /// Whether the URL points inside this store's durable draft directory.
    public func isOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard let directory = storageDirectory(createIfMissing: false) else { return false }
        let directoryPath = directory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private func copyToDurableStorage(_ sourceURL: URL) -> URL? {
        let sourceURL = sourceURL.standardizedFileURL
        guard let destinationURL = durableStorageURL(for: sourceURL) else { return nil }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL.standardizedFileURL
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL.standardizedFileURL
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                return destinationURL.standardizedFileURL
            }
            return nil
        }
    }

    private func linkToDurableStorageIfPossible(_ sourceURL: URL) -> URL? {
        let sourceURL = sourceURL.standardizedFileURL
        guard let destinationURL = durableStorageURL(for: sourceURL) else { return nil }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                return destinationURL
            }
            return nil
        }
    }

    private func durableStorageURL(for sourceURL: URL) -> URL? {
        guard let directory = storageDirectory() else { return nil }
        let sourceURL = sourceURL.standardizedFileURL
        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathToken = stablePathToken(sourceURL.path)
        let fallbackName = fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"
        let filename = "\(pathToken)-\(sourceURL.lastPathComponent.isEmpty ? fallbackName : sourceURL.lastPathComponent)"
        return directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
    }

    private func stablePathToken(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func storageDirectory(createIfMissing: Bool = true) -> URL? {
        guard let appSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if createIfMissing {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }

#if DEBUG
    /// Synchronously stages a durable copy for the given original temporary file
    /// path and records it as the durable copy, for tests that need the copy on
    /// disk before asserting.
    public func debugPrepareDurableCopySynchronously(forTemporaryFileAtPath originalPath: String) -> URL? {
        let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
        guard let durableURL = copyToDurableStorage(originalURL) else {
            return nil
        }
        draftCopyState.withLock { state in
            state.pendingOriginalPaths.remove(originalURL.path)
            state.cancelledOriginalPaths.remove(originalURL.path)
            state.copiedDraftPathByOriginalPath[originalURL.path] = durableURL.path
        }
        return durableURL
    }
#endif
}
