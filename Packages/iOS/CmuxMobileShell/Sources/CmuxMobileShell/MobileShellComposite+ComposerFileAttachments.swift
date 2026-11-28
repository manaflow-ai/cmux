internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    /// Whether the FOREGROUND Mac advertises the chunked task-attachment upload
    /// verb the terminal composer's file sends ride on. Stage-time gate for
    /// pasting files into the composer; the send-time upload re-checks the
    /// capability authoritatively.
    public var supportsComposerFileAttachments: Bool {
        supportedHostCapabilities.contains(Self.taskAttachmentCapability)
    }

    /// Uploads one staged composer FILE attachment to the foreground Mac and
    /// returns its final absolute path there.
    ///
    /// The pending attachment's bytes live in memory (like staged images), while
    /// the shared task-attachment uploader reads from a file, so the bytes are
    /// written to an app-owned temp file for the duration of the upload and
    /// always removed afterwards. The attachment's own id serves as BOTH the
    /// operation id and the upload id: the Mac store answers a re-upload of a
    /// completed (operation, upload) pair with the existing path, so retrying
    /// after a failed text send reuses the already-uploaded file instead of
    /// orphaning one copy per attempt.
    func uploadPendingFileAttachment(
        _ attachment: MobilePendingAttachment
    ) async -> Result<String, MobileWorkspaceMutationFailure> {
        guard attachment.kind == .file, let macDeviceID = foregroundMacDeviceID else {
            return .failure(.notConnected(hostDisplayName: nil))
        }
        let fileName = attachment.displayName
            ?? "pasted-file" + (attachment.format.isEmpty ? "" : ".\(attachment.format)")
        let suffix = attachment.format.isEmpty ? "" : ".\(attachment.format)"
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-composer-upload-\(UUID().uuidString)\(suffix)")
        do {
            try await writeStagedBytes(attachment.data, to: stagedURL)
        } catch {
            return .failure(.rejected(hostDisplayName: nil))
        }
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let staged = TaskComposerAttachment(
            id: attachment.id,
            kind: .file,
            displayName: fileName,
            localStagedFileURL: stagedURL,
            byteCount: attachment.data.count
        )
        return await uploadTaskAttachment(
            staged,
            operationID: attachment.id,
            macDeviceID: macDeviceID,
            instanceTag: activeMacInstanceTag
        )
    }

    /// Write the staged bytes off the main actor so a multi-MB file does not
    /// stall the composer mid-send.
    private func writeStagedBytes(_ data: Data, to url: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
            }
            try await group.waitForAll()
        }
    }
}
