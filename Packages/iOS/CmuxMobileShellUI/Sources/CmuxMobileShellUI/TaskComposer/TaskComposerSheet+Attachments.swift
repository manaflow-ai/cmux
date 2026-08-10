#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxAgentChatUI
import Foundation
import PhotosUI
import SwiftUI

extension TaskComposerSheet {
    var showsAttachmentButton: Bool {
        guard selectedTemplate?.isPlainShell == false,
              !selectedMacDeviceID.isEmpty else {
            return false
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
            return
        }
        isAttachmentPhotoPickerPresented = true
    }

    func presentAttachmentFileImporter() {
        guard remainingAttachmentCount > 0 else {
            attachmentAlertMessage = Self.attachmentCountFailureMessage
            return
        }
        isAttachmentFileImporterPresented = true
    }

    func stageSelectedPhotos(_ items: [PhotosPickerItem]) {
        attachmentStagingTask?.cancel()
        let generation = UUID()
        attachmentStagingGeneration = generation
        attachmentStagingTask = Task { @MainActor in
            defer {
                attachmentPhotoSelection = []
                if attachmentStagingGeneration == generation {
                    attachmentStagingTask = nil
                }
            }
            for item in items.prefix(remainingAttachmentCount) {
                guard !Task.isCancelled,
                      attachmentStagingGeneration == generation else { return }
                do {
                    guard let imported = try await item.loadTransferable(
                        type: MobileImportedImageFile.self
                    ) else {
                        throw TaskComposerAttachmentStager.StagingError.unreadableFile
                    }
                    defer {
                        try? FileManager.default.removeItem(at: imported.url)
                    }
                    let attachment = try await TaskComposerAttachmentStager()
                        .stageImage(
                            at: imported.url,
                            originalFileName: imported.originalFileName
                        )
                    guard !Task.isCancelled,
                          attachmentStagingGeneration == generation else {
                        try? FileManager.default.removeItem(
                            at: attachment.localStagedFileURL
                        )
                        return
                    }
                    appendAttachment(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    attachmentAlertMessage = Self.attachmentStagingFailureMessage(
                        error
                    )
                }
            }
        }
    }

    func stageSelectedFiles(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            if case let .failure(error) = result,
               (error as? CocoaError)?.code == .userCancelled {
                return
            }
            attachmentAlertMessage = Self.attachmentUnreadableFailureMessage
            return
        }
        let availableCount = remainingAttachmentCount
        if urls.count > availableCount {
            attachmentAlertMessage = Self.attachmentCountFailureMessage
        }
        attachmentStagingTask?.cancel()
        let generation = UUID()
        attachmentStagingGeneration = generation
        attachmentStagingTask = Task { @MainActor in
            defer {
                if attachmentStagingGeneration == generation {
                    attachmentStagingTask = nil
                }
            }
            for url in urls.prefix(availableCount) {
                guard !Task.isCancelled,
                      attachmentStagingGeneration == generation else { return }
                do {
                    let attachment = try await TaskComposerAttachmentStager()
                        .stageFile(at: url)
                    guard !Task.isCancelled,
                          attachmentStagingGeneration == generation else {
                        try? FileManager.default.removeItem(
                            at: attachment.localStagedFileURL
                        )
                        return
                    }
                    appendAttachment(attachment)
                } catch is CancellationError {
                    return
                } catch {
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
            return
        }
        guard totalBytes + attachment.byteCount
                <= TaskComposerAttachment.maximumTotalBytes else {
            try? FileManager.default.removeItem(
                at: attachment.localStagedFileURL
            )
            attachmentAlertMessage = Self.attachmentTotalSizeFailureMessage
            return
        }
        updateSubmissionRequest(reconcileRecovery: true) {
            attachments.append(attachment)
        }
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
        case .fileTooLarge:
            return L10n.string(
                "mobile.taskComposer.attachments.fileTooLarge",
                defaultValue: "Choose a file 32 MB or smaller."
            )
        case .unreadableFile:
            return attachmentUnreadableFailureMessage
        }
    }
}
#endif
