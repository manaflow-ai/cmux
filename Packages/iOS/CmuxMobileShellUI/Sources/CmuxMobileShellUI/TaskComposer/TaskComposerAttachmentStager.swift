#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

/// Exact-byte staging shared with Terminal and Agent Chat.
struct TaskComposerAttachmentStager: Sendable {
    enum StagingError: Error {
        case fileTooLarge
        case unreadableFile
    }

    func stageImage(
        at sourceURL: URL,
        originalFileName: String
    ) async throws -> TaskComposerAttachment {
        try await stage(
            at: sourceURL,
            kind: .image,
            originalFileName: originalFileName
        )
    }

    func stageFile(at sourceURL: URL) async throws -> TaskComposerAttachment {
        try await stage(
            at: sourceURL,
            kind: .file,
            originalFileName: sourceURL.lastPathComponent
        )
    }

    private func stage(
        at sourceURL: URL,
        kind: MobileStagedAttachment.Kind,
        originalFileName: String
    ) async throws -> TaskComposerAttachment {
        do {
            return try await MobileAttachmentStager().stage(
                sourceURL: sourceURL,
                kind: kind,
                originalFileName: originalFileName
            )
        } catch MobileAttachmentStager.StagingError.fileTooLarge {
            throw StagingError.fileTooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StagingError.unreadableFile
        }
    }
}
#endif
