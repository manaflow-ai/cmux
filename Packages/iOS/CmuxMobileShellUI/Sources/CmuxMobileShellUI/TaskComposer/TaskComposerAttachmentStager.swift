#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// Copies picked files into app-owned temporary storage for one composer session.
struct TaskComposerAttachmentStager: Sendable {
    enum StagingError: Error {
        case imageRejected
        case fileTooLarge
        case unreadableFile
    }

    func stageImage(
        at sourceURL: URL,
        originalFileName: String
    ) async throws -> TaskComposerAttachment {
        let sourceByteCount = try sourceFileByteCount(at: sourceURL)
        guard sourceByteCount <= MobileImageAttachmentPreparer.maximumRawInputBytes else {
            throw StagingError.imageRejected
        }
        guard let prepared = await MobileImageAttachmentPreparer().prepare(url: sourceURL),
              prepared.data.count <= TaskComposerAttachment.maximumImageBytes else {
            throw StagingError.imageRejected
        }
        let displayName = imageDisplayName(
            originalFileName: originalFileName,
            format: prepared.format
        )
        let stagedURL = temporaryURL(fileExtension: prepared.format)
        do {
            try prepared.data.write(to: stagedURL, options: .atomic)
        } catch {
            throw StagingError.unreadableFile
        }
        return TaskComposerAttachment(
            kind: .image,
            displayName: displayName,
            localStagedFileURL: stagedURL,
            byteCount: prepared.data.count,
            thumbnailData: prepared.thumbnailData
        )
    }

    func stageFile(at sourceURL: URL) async throws -> TaskComposerAttachment {
        try await withThrowingTaskGroup(of: TaskComposerAttachment.self) { group in
            group.addTask(priority: .utility) {
                let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                let byteCount: Int
                do {
                    let values = try sourceURL.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile == true, let size = values.fileSize else {
                        throw StagingError.unreadableFile
                    }
                    byteCount = size
                } catch let error as StagingError {
                    throw error
                } catch {
                    throw StagingError.unreadableFile
                }
                guard byteCount <= TaskComposerAttachment.maximumFileBytes else {
                    throw StagingError.fileTooLarge
                }
                let destination = temporaryURL(
                    fileExtension: sourceURL.pathExtension
                )
                do {
                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: destination
                    )
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw StagingError.unreadableFile
                }
                return TaskComposerAttachment(
                    kind: .file,
                    displayName: sourceURL.lastPathComponent,
                    localStagedFileURL: destination,
                    byteCount: byteCount
                )
            }
            guard let attachment = try await group.next() else {
                throw CancellationError()
            }
            return attachment
        }
    }

    private func sourceFileByteCount(at url: URL) throws -> Int {
        guard let byteCount = try url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            throw StagingError.unreadableFile
        }
        return byteCount
    }

    private func imageDisplayName(
        originalFileName: String,
        format: String
    ) -> String {
        let original = originalFileName as NSString
        let rawStem = original.deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = rawStem.isEmpty ? UUID().uuidString : rawStem
        return "\(stem).\(format)"
    }

    private func temporaryURL(fileExtension: String) -> URL {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-task-attachment-\(UUID().uuidString)\(suffix)"
            )
    }
}
#endif
