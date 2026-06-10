import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Attachment File Cleanup
extension TextBoxInputTextView {
    func queueAutomaticAttachmentFileCleanup(in range: NSRange) {
        guard !suppressAutomaticAttachmentFileCleanup else { return }
        let removedAttachments = inlineAttachments(in: range)
        guard !removedAttachments.isEmpty else { return }
        for attachment in removedAttachments {
            guard attachment.cleanupLocalURLWhenDisposed,
                  let localURL = attachment.localURL else { continue }
            pendingAutomaticAttachmentFileCleanup[Self.attachmentCleanupKey(for: localURL)] = attachment
        }
    }

    func flushAutomaticAttachmentFileCleanup() {
        guard !pendingAutomaticAttachmentFileCleanup.isEmpty else { return }
        let attachments = Array(pendingAutomaticAttachmentFileCleanup.values)
        pendingAutomaticAttachmentFileCleanup.removeAll(keepingCapacity: true)
        cleanupRemovedAttachmentFiles(attachments)
    }

    func cleanupDisposableAttachmentFiles(
        _ attachments: [TextBoxAttachment],
        preservingActiveInlineAttachments: Bool = true
    ) {
        let activeKeys = preservingActiveInlineAttachments ? activeInlineAttachmentCleanupKeys() : []
        var urlsToClean: [URL] = []
        for attachment in attachments {
            guard attachment.cleanupLocalURLWhenDisposed,
                  let url = attachment.localURL else { continue }
            let key = Self.attachmentCleanupKey(for: url)
            pendingUndoableAttachmentFileCleanup.removeValue(forKey: key)
            guard !activeKeys.contains(key) else { continue }
            urlsToClean.append(url)
        }

        let ghosttyTemporaryURLs = urlsToClean.filter { url in
            TextBoxDraftAttachmentStorage.removeCopiedDraftForOriginalTemporaryFile(url)
            return !TextBoxDraftAttachmentStorage.removeIfOwnedDraftCopy(url)
        }
        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(ghosttyTemporaryURLs)
    }

    func cleanupCopiedDraftFilesForPreservedLocalPathSubmissions(_ attachments: [TextBoxAttachment]) {
        for attachment in attachments where attachment.cleanupLocalURLWhenDisposed && attachment.submitsLocalFilePath {
            guard let localURL = attachment.localURL else { continue }
            TextBoxDraftAttachmentStorage.removeCopiedDraftForOriginalTemporaryFile(localURL)
        }
    }

    func cleanupPendingUndoableAttachmentFiles() {
        guard !pendingUndoableAttachmentFileCleanup.isEmpty else { return }
        let activePaths = activeInlineAttachmentCleanupKeys()
        var attachmentsToClean: [TextBoxAttachment] = []
        let cleanupKeys = pendingUndoableAttachmentFileCleanup.keys.filter { !activePaths.contains($0) }
        for key in cleanupKeys {
            if let attachment = pendingUndoableAttachmentFileCleanup.removeValue(forKey: key) {
                attachmentsToClean.append(attachment)
            }
        }
        cleanupDisposableAttachmentFiles(attachmentsToClean)
    }

    func discardUndoHistoryAndCleanupPendingAttachmentFiles() {
        flushAutomaticAttachmentFileCleanup()
        undoManager?.removeAllActions()
        removeActiveAttachmentsFromPendingCleanup()
        cleanupPendingUndoableAttachmentFiles()
    }

    private func removeActiveAttachmentsFromPendingCleanup() {
        guard !pendingUndoableAttachmentFileCleanup.isEmpty else { return }
        for key in activeInlineAttachmentCleanupKeys() {
            pendingUndoableAttachmentFileCleanup.removeValue(forKey: key)
        }
    }

    func removePendingAttachmentCleanup(for attachments: [TextBoxAttachment]) {
        guard !pendingUndoableAttachmentFileCleanup.isEmpty else { return }
        for attachment in attachments {
            guard let localURL = attachment.localURL else { continue }
            pendingUndoableAttachmentFileCleanup.removeValue(
                forKey: Self.attachmentCleanupKey(for: localURL)
            )
        }
    }

    func cleanupRemovedAttachmentFiles(_ attachments: [TextBoxAttachment]) {
        guard allowsUndo,
              undoManager?.isUndoRegistrationEnabled == true else {
            cleanupDisposableAttachmentFiles(attachments)
            return
        }
        deferUndoableAttachmentFileCleanup(attachments)
    }

    private func deferUndoableAttachmentFileCleanup(_ attachments: [TextBoxAttachment]) {
        let activePaths = activeInlineAttachmentCleanupKeys()
        for attachment in attachments {
            guard attachment.cleanupLocalURLWhenDisposed,
                  let localURL = attachment.localURL else { continue }
            let key = Self.attachmentCleanupKey(for: localURL)
            guard !activePaths.contains(key) else { continue }
            pendingUndoableAttachmentFileCleanup[key] = attachment
        }
    }

    private func activeInlineAttachmentCleanupKeys() -> Set<String> {
        Set(inlineAttachments().compactMap { attachment in
            attachment.localURL.map(Self.attachmentCleanupKey(for:))
        })
    }

    private static func attachmentCleanupKey(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }

}
