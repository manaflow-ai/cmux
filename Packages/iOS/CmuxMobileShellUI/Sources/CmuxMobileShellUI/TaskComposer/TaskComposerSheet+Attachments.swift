#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import PhotosUI
import SwiftUI

extension TaskComposerSheet {
    var showsAttachmentButton: Bool {
        guard selectedTemplate?.isPlainShell == false,
              !selectedMacDeviceID.isEmpty else {
            return false
        }
        if let taskAttachmentsCapabilityOverride {
            return taskAttachmentsCapabilityOverride
        }
        return store.supportsTaskAttachments(
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag
        )
    }

    var remainingAttachmentCount: Int {
        max(TaskComposerAttachment.maximumCount - attachments.count, 0)
    }

    func presentAttachmentPhotoPicker() {
        guard remainingAttachmentCount > 0 else {
            attachmentAlertMessage = Self.attachmentCountFailureMessage
            store.recordAppEvent(
                .taskAttachmentLimitReached,
                failure: .attachmentCountLimitReached,
                count: attachments.count
            )
            return
        }
        store.recordAppEvent(.taskAttachmentPickerOpened)
        store.recordAppEvent(.photoPickerOpened)
        isAttachmentPhotoPickerPresented = true
    }

    func presentAttachmentFileImporter() {
        guard remainingAttachmentCount > 0 else {
            attachmentAlertMessage = Self.attachmentCountFailureMessage
            store.recordAppEvent(
                .taskAttachmentLimitReached,
                failure: .attachmentCountLimitReached,
                count: attachments.count
            )
            return
        }
        store.recordAppEvent(.taskAttachmentPickerOpened)
        isAttachmentFileImporterPresented = true
    }

    /// Stage the pasteboard's image/file content as task attachments. The
    /// shared action behind the prompt editor's system Paste and the attachment
    /// menu's Paste item.
    ///
    /// - Returns: `true` when the paste was consumed as attachment content (so
    ///   the editor must not also insert text), `false` when the pasteboard has
    ///   no attachment content or attachments are not available here — native
    ///   text paste then proceeds untouched. The availability gate is the SAME
    ///   one that hides the attachment button (plain-shell templates and Macs
    ///   without the task-attachment capability), so a paste cannot smuggle an
    ///   attachment past the UI gate.
    func stagePasteboardAttachments() -> Bool {
        guard showsAttachmentButton, !submissionPhase.disablesRequestEditing else {
            return false
        }
        let reader = MobilePasteboardReader()
        // Classify BEFORE the count gate: a text-only paste must never be
        // consumed here, even when the attachment list is full.
        guard reader.hasAttachmentContent(in: .general) else { return false }
        guard remainingAttachmentCount > 0 else {
            attachmentAlertMessage = Self.attachmentCountFailureMessage
            store.recordAppEvent(
                .taskAttachmentLimitReached,
                failure: .attachmentCountLimitReached,
                count: attachments.count
            )
            return true
        }
        beginAttachmentStaging {
            let items = await reader.materializeAttachments(from: .general)
            defer { reader.cleanUp(items) }
            guard !Task.isCancelled else { return }
            guard !items.isEmpty else {
                attachmentAlertMessage = Self.attachmentUnreadableFailureMessage
                store.recordAppEvent(
                    .attachmentPreparationFailed,
                    failure: .unknown
                )
                return
            }
            for item in items.prefix(remainingAttachmentCount) {
                guard !Task.isCancelled else { return }
                do {
                    store.recordAppEvent(.attachmentPreparationStarted)
                    let stager = TaskComposerAttachmentStager()
                    let attachment: TaskComposerAttachment = switch item.kind {
                    case .image:
                        try await stager.stageImage(
                            at: item.url,
                            originalFileName: item.displayName
                        )
                    case .file:
                        try await stager.stageFile(at: item.url)
                    }
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(
                            at: attachment.localStagedFileURL
                        )
                        return
                    }
                    appendAttachment(attachment)
                    store.recordAppEvent(
                        .attachmentPreparationSucceeded,
                        correlationID: attachment.id.uuidString,
                        count: attachment.byteCount
                    )
                } catch is CancellationError {
                    store.recordAppEvent(
                        .attachmentPreparationFailed,
                        failure: .cancelled
                    )
                    return
                } catch {
                    store.recordAppEvent(
                        .attachmentPreparationFailed,
                        failure: DiagnosticFailureKind.classify(error)
                    )
                    attachmentAlertMessage = Self.attachmentStagingFailureMessage(
                        error
                    )
                }
            }
        }
        return true
    }

    /// Replace the in-flight staging task with a new one whose completion only
    /// clears the shared handle if it is STILL the current batch. Without the
    /// generation check, a cancelled older batch finishing late would nil out
    /// the newer batch's handle and re-enable submit while staging is still in
    /// flight.
    private func beginAttachmentStaging(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        attachmentStagingTask?.cancel()
        attachmentStagingGeneration += 1
        let generation = attachmentStagingGeneration
        attachmentStagingTask = Task { @MainActor in
            defer {
                if attachmentStagingGeneration == generation {
                    attachmentStagingTask = nil
                }
            }
            await operation()
        }
    }

    func stageSelectedPhotos(_ items: [PhotosPickerItem]) {
        store.recordAppEvent(.photoPickerSelected, count: items.count)
        beginAttachmentStaging {
            defer {
                attachmentPhotoSelection = []
            }
            for item in items.prefix(remainingAttachmentCount) {
                guard !Task.isCancelled else { return }
                do {
                    store.recordAppEvent(.attachmentPreparationStarted)
                    guard let imported = try await item.loadTransferable(
                        type: ImportedImageFile.self
                    ) else {
                        throw TaskComposerAttachmentStager.StagingError.imageRejected
                    }
                    defer {
                        try? FileManager.default.removeItem(at: imported.url)
                    }
                    let attachment = try await TaskComposerAttachmentStager()
                        .stageImage(
                            at: imported.url,
                            originalFileName: imported.originalFileName
                        )
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(
                            at: attachment.localStagedFileURL
                        )
                        return
                    }
                    appendAttachment(attachment)
                    store.recordAppEvent(
                        .attachmentPreparationSucceeded,
                        correlationID: attachment.id.uuidString,
                        count: attachment.byteCount
                    )
                } catch is CancellationError {
                    store.recordAppEvent(
                        .attachmentPreparationFailed,
                        failure: .cancelled
                    )
                    return
                } catch {
                    store.recordAppEvent(
                        .attachmentPreparationFailed,
                        failure: DiagnosticFailureKind.classify(error)
                    )
                    attachmentAlertMessage = Self.attachmentStagingFailureMessage(
                        error
                    )
                }
            }
        }
    }

    func stageSelectedFiles(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            attachmentAlertMessage = Self.attachmentUnreadableFailureMessage
            store.recordAppEvent(
                .attachmentPreparationFailed,
                failure: .permissionDenied
            )
            return
        }
        beginAttachmentStaging {
            for url in urls.prefix(remainingAttachmentCount) {
                guard !Task.isCancelled else { return }
                do {
                    store.recordAppEvent(.attachmentPreparationStarted)
                    let attachment = try await TaskComposerAttachmentStager()
                        .stageFile(at: url)
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(
                            at: attachment.localStagedFileURL
                        )
                        return
                    }
                    appendAttachment(attachment)
                    store.recordAppEvent(
                        .attachmentPreparationSucceeded,
                        correlationID: attachment.id.uuidString,
                        count: attachment.byteCount
                    )
                } catch is CancellationError {
                    store.recordAppEvent(
                        .attachmentPreparationFailed,
                        failure: .cancelled
                    )
                    return
                } catch {
                    store.recordAppEvent(
                        .attachmentPreparationFailed,
                        failure: DiagnosticFailureKind.classify(error)
                    )
                    attachmentAlertMessage = Self.attachmentStagingFailureMessage(
                        error
                    )
                }
            }
        }
    }

    func appendAttachment(_ attachment: TaskComposerAttachment) {
        guard !submissionPhase.disablesRequestEditing else {
            try? FileManager.default.removeItem(
                at: attachment.localStagedFileURL
            )
            return
        }
        let totalBytes = attachments.reduce(0) { $0 + $1.byteCount }
        guard attachments.count < TaskComposerAttachment.maximumCount else {
            try? FileManager.default.removeItem(
                at: attachment.localStagedFileURL
            )
            attachmentAlertMessage = Self.attachmentCountFailureMessage
            store.recordAppEvent(
                .taskAttachmentLimitReached,
                failure: .attachmentCountLimitReached,
                count: attachments.count
            )
            return
        }
        guard totalBytes + attachment.byteCount
                <= TaskComposerAttachment.maximumTotalBytes else {
            try? FileManager.default.removeItem(
                at: attachment.localStagedFileURL
            )
            attachmentAlertMessage = Self.attachmentTotalSizeFailureMessage
            store.recordAppEvent(
                .taskAttachmentLimitReached,
                failure: .attachmentAggregateSizeLimitReached,
                count: totalBytes
            )
            return
        }
        updateSubmissionRequest(reconcileRecovery: true) {
            attachments.append(attachment)
        }
        store.recordAppEvent(
            .taskAttachmentPrepared,
            correlationID: attachment.id.uuidString,
            count: attachments.count
        )
    }

    func removeAttachment(_ id: UUID) {
        guard !submissionPhase.disablesRequestEditing,
              let index = attachments.firstIndex(where: { $0.id == id }) else {
            return
        }
        let attachment = attachments[index]
        updateSubmissionRequest(reconcileRecovery: true) {
            attachments.remove(at: index)
        }
        try? FileManager.default.removeItem(
            at: attachment.localStagedFileURL
        )
        store.recordAppEvent(
            .taskAttachmentRemoved,
            correlationID: id.uuidString,
            count: attachments.count
        )
    }

    func removeStagedAttachmentFiles() {
        for attachment in attachments {
            try? FileManager.default.removeItem(
                at: attachment.localStagedFileURL
            )
        }
    }

    func uploadAttachments(
        for snapshot: MobileTaskSubmissionSnapshot
    ) async -> Result<[String], MobileWorkspaceMutationFailure> {
        guard snapshot.composition.initialCommand != nil else {
            return .success([])
        }
        let attachmentsByID = Dictionary(
            uniqueKeysWithValues: attachments.map { ($0.id, $0) }
        )
        var paths: [String] = []
        for identity in snapshot.attachments {
            guard let attachment = attachmentsByID[identity.uploadID],
                  attachment.byteCount == identity.byteCount else {
                return .failure(.rejected(
                    hostDisplayName: selectedMachine?.resolvedName
                ))
            }
            let result = await store.uploadTaskAttachment(
                attachment,
                operationID: snapshot.operationID,
                macDeviceID: snapshot.macDeviceID,
                instanceTag: snapshot.macInstanceTag
            )
            switch result {
            case .success(let path):
                paths.append(path)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .success(paths)
    }

    static var attachmentCountFailureMessage: String {
        L10n.string(
            "mobile.taskComposer.attachments.limit.count",
            defaultValue: "You can attach up to 10 items to a task."
        )
    }

    static var attachmentTotalSizeFailureMessage: String {
        L10n.string(
            "mobile.taskComposer.attachments.limit.totalSize",
            defaultValue: "Task attachments can use up to 64 MB in total."
        )
    }

    static var attachmentUnreadableFailureMessage: String {
        L10n.string(
            "mobile.taskComposer.attachments.unreadable",
            defaultValue: "That file couldn’t be read. Choose another file."
        )
    }

    static func attachmentStagingFailureMessage(_ error: any Error) -> String {
        guard let stagingError = error
                as? TaskComposerAttachmentStager.StagingError else {
            return attachmentUnreadableFailureMessage
        }
        switch stagingError {
        case .imageRejected:
            return L10n.string(
                "mobile.taskComposer.attachments.imageRejected",
                defaultValue: "That image couldn’t be compressed below 8 MB."
            )
        case .fileTooLarge:
            return L10n.string(
                "mobile.taskComposer.attachments.fileTooLarge",
                defaultValue: "Choose a file smaller than 32 MB."
            )
        case .unreadableFile:
            return attachmentUnreadableFailureMessage
        }
    }
}
#endif
