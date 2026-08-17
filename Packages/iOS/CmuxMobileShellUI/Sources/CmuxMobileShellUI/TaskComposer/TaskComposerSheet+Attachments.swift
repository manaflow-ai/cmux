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

    func stageSelectedPhotos(_ items: [PhotosPickerItem]) {
        store.recordAppEvent(.photoPickerSelected, count: items.count)
        attachmentStagingTask?.cancel()
        attachmentStagingTask = Task { @MainActor in
            defer {
                attachmentPhotoSelection = []
                attachmentStagingTask = nil
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
        attachmentStagingTask?.cancel()
        attachmentStagingTask = Task { @MainActor in
            defer { attachmentStagingTask = nil }
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
