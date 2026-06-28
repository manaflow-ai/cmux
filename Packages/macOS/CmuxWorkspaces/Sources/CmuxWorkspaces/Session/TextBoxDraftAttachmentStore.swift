public import Foundation
public import CmuxTerminalCore
import os

/// The process-wide copy-state machine for textbox draft attachments.
///
/// Textbox attachment drafts live in temporary image files the pasteboard owns.
/// To survive an app relaunch (termination / update restart) each draft needs a
/// durable copy outside that temporary directory. This store owns the path/URL
/// lifecycle of those copies: it tracks which originals have a durable copy,
/// which are mid-copy, and which were cancelled while a copy was in flight, all
/// behind one `OSAllocatedUnfairLock`. The leaf file-system math (where a copy
/// lives, link-vs-copy) belongs to the injected ``TextBoxDraftAttachmentDurableStorage``.
///
/// A single shared instance is held at the app composition root so the
/// copy-state is process-wide, exactly as it was when this state lived in
/// `static` storage. The pasteboard checks and `TextBoxAttachment`-typed snapshot
/// logic stay app-side and forward path/URL work here.
public final class TextBoxDraftAttachmentStore: Sendable {
    private struct DraftCopyState {
        var copiedDraftPathByOriginalPath: [String: String] = [:]
        var pendingOriginalPaths: Set<String> = []
        var cancelledOriginalPaths: Set<String> = []
    }

    private let draftCopyState = OSAllocatedUnfairLock(
        initialState: DraftCopyState()
    )

    private let durableStorage: TextBoxDraftAttachmentDurableStorage

    /// Decides whether a candidate local file is a pasteboard-owned temporary
    /// image, the only kind of attachment that gets a durable draft copy. The
    /// app injects ``TerminalPasteboardService`` here so the moved snapshot
    /// bodies name no app symbol.
    private let pasteboard: any TerminalImagePasteWriting

    /// Builds the shell-submission text for a local file URL. The app injects
    /// `TextBoxAttachment.submissionText(forLocalFileURL:)` so the durable
    /// snapshot's submission fields stay byte-identical to the live attachment's
    /// without this package depending on the app `TerminalImageTransferPlanner`.
    private let submissionTextForLocalFileURL: @Sendable (URL) -> String

    /// Creates a draft-attachment store.
    ///
    /// - Parameters:
    ///   - durableStorage: The leaf file-system primitives backing each durable
    ///     copy, injected for testability.
    ///   - pasteboard: The pasteboard ownership oracle used to gate which local
    ///     files get a durable draft copy.
    ///   - submissionTextForLocalFileURL: Resolves a local file URL to the text
    ///     inserted when the draft is submitted.
    public init(
        durableStorage: TextBoxDraftAttachmentDurableStorage = TextBoxDraftAttachmentDurableStorage(),
        pasteboard: any TerminalImagePasteWriting,
        submissionTextForLocalFileURL: @escaping @Sendable (URL) -> String
    ) {
        self.durableStorage = durableStorage
        self.pasteboard = pasteboard
        self.submissionTextForLocalFileURL = submissionTextForLocalFileURL
    }

    /// Returns whether `fileURL` belongs to this app-owned durable draft store.
    public func isOwnedDraftCopy(_ fileURL: URL) -> Bool {
        durableStorage.isOwnedDraftCopy(fileURL)
    }

    /// Builds the durable session snapshot for a draft attachment.
    ///
    /// When `localURL` is a pasteboard-owned temporary image that still exists
    /// on disk, this starts (or reuses) a durable copy and, once available,
    /// returns a snapshot pointing at the durable file with rewritten submission
    /// fields. In every other case it returns `fallback` unchanged. Regular
    /// autosaves do not block on file copies; termination / update-relaunch
    /// saves flush pending copies first so the durable lookup is already
    /// satisfied here.
    ///
    /// - Parameters:
    ///   - fallback: The snapshot built directly from the live attachment's
    ///     fields, used whenever no durable copy applies.
    ///   - localURL: The attachment's live local file URL, if any.
    public func durableSnapshot(
        fallback: SessionTextBoxInputAttachmentSnapshot,
        localURL: URL?
    ) -> SessionTextBoxInputAttachmentSnapshot {
        guard let localURL,
              pasteboard.isOwnedTemporaryImageFile(localURL) else {
            return fallback
        }
        let standardizedLocalURL = localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedLocalURL.path) else {
            return fallback
        }

        // Regular autosaves should not block the main thread on file copies.
        // Termination/update relaunch saves flush pending draft copies before
        // building the session snapshot so this lookup is already durable there.
        prepareDurableCopy(forTemporaryFileAtPath: standardizedLocalURL.path)
        guard let durableURL = copiedDraftURL(forOriginalURL: standardizedLocalURL) else {
            return fallback
        }
        let submissionFields = copiedSubmissionFields(
            fallback: fallback,
            originalLocalURL: standardizedLocalURL,
            durableURL: durableURL
        )
        return SessionTextBoxInputAttachmentSnapshot(
            displayName: fallback.displayName,
            submissionText: submissionFields.text,
            submissionPath: submissionFields.path,
            localPath: durableURL.path,
            cleanupLocalPathWhenDisposed: true
        )
    }

    /// Starts a durable copy for a draft attachment's `localURL` when it is a
    /// pasteboard-owned temporary image that exists on disk.
    public func prepareDurableCopy(localURL: URL?) {
        guard let localURL,
              pasteboard.isOwnedTemporaryImageFile(localURL) else {
            return
        }
        let standardizedLocalURL = localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedLocalURL.path) else { return }
        prepareDurableCopy(forTemporaryFileAtPath: standardizedLocalURL.path)
    }

    /// Resolves the submission `(text, path)` for a durable copy, preserving the
    /// fallback fields whenever the live attachment submitted something other
    /// than its own local file (so a custom submission text/path survives).
    private func copiedSubmissionFields(
        fallback: SessionTextBoxInputAttachmentSnapshot,
        originalLocalURL: URL,
        durableURL: URL
    ) -> (text: String, path: String) {
        let originalLocalURL = originalLocalURL.standardizedFileURL
        let originalLocalSubmissionText = submissionTextForLocalFileURL(originalLocalURL)
        guard fallback.submissionPath == originalLocalURL.path,
              fallback.submissionText == originalLocalSubmissionText else {
            return (fallback.submissionText, fallback.submissionPath)
        }
        return (submissionTextForLocalFileURL(durableURL), durableURL.path)
    }

    /// Removes `fileURL` from disk when it belongs to the durable store,
    /// returning whether it was an owned draft copy.
    public func removeIfOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard durableStorage.isOwnedDraftCopy(fileURL) else { return false }
        try? FileManager.default.removeItem(at: fileURL.standardizedFileURL)
        return true
    }

    /// Forgets (and deletes) the durable copy made for `fileURL`, cancelling any
    /// in-flight copy so its eventual result is discarded.
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

    /// Resolves the durable copy URL recorded for `originalURL`, pruning the
    /// record and returning `nil` when the copy no longer exists on disk.
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

    /// Starts a durable copy for the temporary file at `originalPath` if one is
    /// not already present, in flight, or cancelled. Links synchronously when the
    /// file system allows it, otherwise copies on a detached utility task.
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
        if let durableURL = durableStorage.linkToDurableStorageIfPossible(originalURL) {
            draftCopyState.withLock { state in
                state.pendingOriginalPaths.remove(originalPath)
                state.cancelledOriginalPaths.remove(originalPath)
                state.copiedDraftPathByOriginalPath[originalPath] = durableURL.path
            }
            return
        }

        Task.detached(priority: .utility) {
            let durableURL = self.durableStorage.copyToDurableStorage(originalURL)
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

    /// Synchronously materializes every pending durable copy, used on
    /// termination / update-relaunch saves so draft snapshots are durable before
    /// the app exits.
    public func flushPendingCopiesSynchronously() {
        let pendingOriginalPaths = draftCopyState.withLock { state in
            Array(state.pendingOriginalPaths)
        }
        for originalPath in pendingOriginalPaths {
            let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
            let durableURL = durableStorage.linkToDurableStorageIfPossible(originalURL)
                ?? durableStorage.copyToDurableStorage(originalURL)
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
}

#if DEBUG
extension TextBoxDraftAttachmentStore {
    /// Test-only: synchronously copies `originalURL` into durable storage and
    /// records it in the copy-state machine, bypassing the async pipeline.
    public func debugPrepareDurableCopySynchronously(forOriginalURL originalURL: URL) -> URL? {
        let originalURL = originalURL.standardizedFileURL
        guard let durableURL = durableStorage.copyToDurableStorage(originalURL) else {
            return nil
        }
        draftCopyState.withLock { state in
            state.pendingOriginalPaths.remove(originalURL.path)
            state.cancelledOriginalPaths.remove(originalURL.path)
            state.copiedDraftPathByOriginalPath[originalURL.path] = durableURL.path
        }
        return durableURL
    }

    /// Test-only: synchronously materializes a durable copy for a draft
    /// attachment's `localURL`, gated on the same pasteboard ownership check as
    /// the production path.
    public func debugPrepareDurableCopySynchronously(localURL: URL?) -> URL? {
        guard let localURL,
              pasteboard.isOwnedTemporaryImageFile(localURL) else {
            return nil
        }
        return debugPrepareDurableCopySynchronously(forOriginalURL: localURL.standardizedFileURL)
    }
}
#endif
