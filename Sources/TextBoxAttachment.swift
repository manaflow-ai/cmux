import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Attachment Model & Draft Storage
struct TextBoxAttachment: Identifiable {
    let id = UUID()
    let displayName: String
    let submissionText: String
    let submissionPath: String
    let localURL: URL?
    let thumbnail: NSImage?
    let cleanupLocalURLWhenDisposed: Bool

    init(
        displayName: String,
        submissionText: String,
        submissionPath: String,
        localURL: URL?,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = localURL?.standardizedFileURL
        let fallbackName = standardizedURL?.lastPathComponent ?? URL(fileURLWithPath: submissionPath).lastPathComponent
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackName.isEmpty ? submissionPath : fallbackName)
            : displayName
        self.submissionText = submissionText
        self.submissionPath = submissionPath
        self.localURL = standardizedURL
        self.thumbnail = standardizedURL.flatMap { TextBoxAttachment.makeThumbnail(for: $0) }
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }

    init(
        localURL: URL,
        submissionText: String,
        submissionPath: String? = nil,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = localURL.standardizedFileURL
        self.displayName = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path
            : standardizedURL.lastPathComponent
        self.submissionText = submissionText
        self.submissionPath = submissionPath ?? standardizedURL.path
        self.localURL = standardizedURL
        self.thumbnail = TextBoxAttachment.makeThumbnail(for: standardizedURL)
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }

    var isImage: Bool {
        if thumbnail != nil { return true }
        guard let localURL else { return false }
        return TextBoxAttachment.isImageFileURL(localURL)
    }

    var submitsLocalFilePath: Bool {
        guard let localURL else { return false }
        let standardizedLocalURL = localURL.standardizedFileURL
        return submissionPath == standardizedLocalURL.path
            || submissionText == Self.submissionText(forLocalFileURL: standardizedLocalURL)
    }

    static func submissionText(forLocalFileURL url: URL) -> String {
        TerminalImageTransferPlanner.insertedText(forFileURLs: [url.standardizedFileURL])
    }

    static func submissionText(forPath path: String) -> String {
        TerminalImageTransferPlanner.insertedText(forPathStrings: [path])
    }

    static func shouldCleanupLocalURLWhenDisposed(_ fileURL: URL) -> Bool {
        GhosttyPasteboardHelper.isOwnedTemporaryImageFile(fileURL)
            || TextBoxDraftAttachmentStorage.isOwnedDraftCopy(fileURL)
    }

    private static func makeThumbnail(for url: URL) -> NSImage? {
        guard TextBoxAttachment.isImageFileURL(url),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

enum TextBoxDraftAttachmentStorage {
    private static let directoryName = "textbox-draft-attachments"
    private struct DraftCopyState {
        var copiedDraftPathByOriginalPath: [String: String] = [:]
        var pendingOriginalPaths: Set<String> = []
        var cancelledOriginalPaths: Set<String> = []
    }

    private nonisolated static let draftCopyState = OSAllocatedUnfairLock(
        initialState: DraftCopyState()
    )

    static func snapshot(for attachment: TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot {
        guard let localURL = attachment.localURL,
              GhosttyPasteboardHelper.isOwnedTemporaryImageFile(localURL) else {
            return fallbackSnapshot(for: attachment)
        }
        let standardizedLocalURL = localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedLocalURL.path) else {
            return fallbackSnapshot(for: attachment)
        }

        // Regular autosaves should not block the main thread on file copies.
        // Termination/update relaunch saves flush pending draft copies before
        // building the session snapshot so this lookup is already durable there.
        prepareDurableCopy(forTemporaryFileAtPath: standardizedLocalURL.path)
        guard let durableURL = copiedDraftURL(forOriginalURL: standardizedLocalURL) else {
            return fallbackSnapshot(for: attachment)
        }
        let submissionFields = copiedSubmissionFields(
            for: attachment,
            originalLocalURL: standardizedLocalURL,
            durableURL: durableURL
        )
        return SessionTextBoxInputAttachmentSnapshot(
            displayName: attachment.displayName,
            submissionText: submissionFields.text,
            submissionPath: submissionFields.path,
            localPath: durableURL.path,
            cleanupLocalPathWhenDisposed: true
        )
    }

    private static func fallbackSnapshot(for attachment: TextBoxAttachment) -> SessionTextBoxInputAttachmentSnapshot {
        SessionTextBoxInputAttachmentSnapshot(
            displayName: attachment.displayName,
            submissionText: attachment.submissionText,
            submissionPath: attachment.submissionPath,
            localPath: attachment.localURL?.standardizedFileURL.path,
            cleanupLocalPathWhenDisposed: attachment.cleanupLocalURLWhenDisposed
        )
    }

    static func prepareDurableCopy(for attachment: TextBoxAttachment) {
        guard let localURL = attachment.localURL,
              GhosttyPasteboardHelper.isOwnedTemporaryImageFile(localURL) else {
            return
        }
        let standardizedLocalURL = localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedLocalURL.path) else { return }
        prepareDurableCopy(forTemporaryFileAtPath: standardizedLocalURL.path)
    }

    static func removeIfOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard isOwnedDraftCopy(fileURL) else { return false }
        try? FileManager.default.removeItem(at: fileURL.standardizedFileURL)
        return true
    }

    static func removeCopiedDraftForOriginalTemporaryFile(_ fileURL: URL) {
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

    private static func copiedDraftURL(forOriginalURL originalURL: URL) -> URL? {
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

    static func prepareDurableCopy(forTemporaryFileAtPath originalPath: String) {
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
            let durableURL = copyToDurableStorage(originalURL)
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

    static func flushPendingCopiesSynchronously() {
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

    private static func copiedSubmissionFields(
        for attachment: TextBoxAttachment,
        originalLocalURL: URL,
        durableURL: URL
    ) -> (text: String, path: String) {
        let originalLocalURL = originalLocalURL.standardizedFileURL
        let originalLocalSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: originalLocalURL)
        guard attachment.submissionPath == originalLocalURL.path,
              attachment.submissionText == originalLocalSubmissionText else {
            return (attachment.submissionText, attachment.submissionPath)
        }
        return (TextBoxAttachment.submissionText(forLocalFileURL: durableURL), durableURL.path)
    }

    private static func copyToDurableStorage(_ sourceURL: URL) -> URL? {
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

    private static func linkToDurableStorageIfPossible(_ sourceURL: URL) -> URL? {
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

    private static func durableStorageURL(for sourceURL: URL) -> URL? {
        guard let directory = storageDirectory() else { return nil }
        let sourceURL = sourceURL.standardizedFileURL
        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathToken = stablePathToken(sourceURL.path)
        let fallbackName = fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"
        let filename = "\(pathToken)-\(sourceURL.lastPathComponent.isEmpty ? fallbackName : sourceURL.lastPathComponent)"
        return directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
    }

    static func isOwnedDraftCopy(_ fileURL: URL) -> Bool {
        guard let directory = storageDirectory(createIfMissing: false) else { return false }
        let directoryPath = directory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private static func stablePathToken(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func storageDirectory(createIfMissing: Bool = true) -> URL? {
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
    static func debugPrepareDurableCopySynchronously(for attachment: TextBoxAttachment) -> URL? {
        guard let localURL = attachment.localURL,
              GhosttyPasteboardHelper.isOwnedTemporaryImageFile(localURL) else {
            return nil
        }
        let originalURL = localURL.standardizedFileURL
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

#if DEBUG
extension TextBoxAttachment {
    func debugPrepareSessionDraftCopySynchronouslyForTesting() -> URL? {
        TextBoxDraftAttachmentStorage.debugPrepareDurableCopySynchronously(for: self)
    }

    func debugCancelSessionDraftCopyForTesting() {
        guard let localURL else { return }
        TextBoxDraftAttachmentStorage.removeCopiedDraftForOriginalTemporaryFile(localURL)
    }
}
#endif

extension TextBoxInputTextView {
    static func flushPendingSessionDraftAttachmentCopies() {
        TextBoxDraftAttachmentStorage.flushPendingCopiesSynchronously()
    }
}

extension SessionTextBoxInputAttachmentSnapshot {
    init(_ attachment: TextBoxAttachment) {
        self = TextBoxDraftAttachmentStorage.snapshot(for: attachment)
    }

    func textBoxAttachment() -> TextBoxAttachment {
        let restoredLocalURL: URL?
        if let localPath {
            let url = URL(fileURLWithPath: localPath).standardizedFileURL
            restoredLocalURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            restoredLocalURL = nil
        }
        return TextBoxAttachment(
            displayName: displayName,
            submissionText: submissionText,
            submissionPath: submissionPath,
            localURL: restoredLocalURL,
            cleanupLocalURLWhenDisposed: cleanupLocalPathWhenDisposed
        )
    }
}

