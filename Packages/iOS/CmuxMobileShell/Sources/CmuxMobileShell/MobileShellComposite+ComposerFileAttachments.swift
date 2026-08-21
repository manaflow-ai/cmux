public import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Uploads one staged composer FILE attachment to the foreground Mac at
    /// send time and returns the Mac-local path to reference in the sent text.
    ///
    /// The staged bytes live in memory (like image attachments); the chunked
    /// upload transport reads from a file, so the bytes are written to an
    /// app-owned temporary file for the duration of the upload and always
    /// removed afterwards, on every exit.
    ///
    /// - Parameter attachment: A staged ``MobilePendingAttachment`` of kind
    ///   ``MobilePendingAttachment/Kind/file``.
    /// - Returns: The final absolute Mac path, or a user-actionable failure.
    func uploadPendingFileAttachment(
        _ attachment: MobilePendingAttachment
    ) async -> Result<String, MobileWorkspaceMutationFailure> {
        let suffix = attachment.format.isEmpty ? "" : ".\(attachment.format)"
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-composer-upload-\(attachment.id.uuidString)\(suffix)"
            )
        do {
            try await Self.writeStagedBytes(attachment.data, to: stagedURL)
        } catch {
            return .failure(.rejected(hostDisplayName: nil))
        }
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let staged = TaskComposerAttachment(
            id: attachment.id,
            kind: .file,
            displayName: attachment.displayName,
            localStagedFileURL: stagedURL,
            byteCount: attachment.data.count
        )
        return await uploadTerminalComposerAttachment(staged)
    }

    /// Writes the staged bytes on a utility child task so a multi-MB file never
    /// blocks the main actor mid-send.
    private nonisolated static func writeStagedBytes(
        _ data: Data,
        to url: URL
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
            }
            try await group.waitForAll()
        }
    }
}
