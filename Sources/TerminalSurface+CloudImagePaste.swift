import CmuxCloud
import AppKit
import CmuxCloudImagePaste
import CmuxTerminal

extension TerminalSurface {
    /// Runs only for a managed Cloud paste plan; there is deliberately no text fallback.
    ///
    /// - Parameter cleansUpTransferredFiles: Whether to delete the files once the
    ///   paste ends. A composer submit passes `false`: its attachments own the
    ///   files, a failed submit restores them into the draft for a retry, and a
    ///   successful one disposes of them with the rest of the submission.
    @MainActor
    func pasteCloudImages(
        _ urls: [URL],
        operation: TerminalImageTransferOperation = TerminalImageTransferOperation(),
        cleansUpTransferredFiles: Bool = true
    ) async throws {
        let pasteboard = GhosttyApp.terminalPasteboard
        var ownsPreparation = false
        do {
            let session = hostedView.cloudTerminalOverlay.session
            guard let session else { throw CloudImagePasteError.unavailable }
            let generation = try session.imagePaste.beginPreparation()
            ownsPreparation = true
            defer {
                session.imagePaste.endPreparation()
                // A replay refetch can be deferred while the image transaction
                // owns the attachment. The paste coordinator clears its active
                // token before this defer runs, so retry the fidelity decision
                // after releasing the preparation reservation.
                session.scheduleFidelityCheck()
                if cleansUpTransferredFiles { pasteboard.cleanupTransferredTemporaryImageFiles(urls) }
            }
            try Task.checkCancellation()
            guard ManagedFileTransferPolicy.isEnabled else {
                throw ManagedFileTransferPolicy.refusalError()
            }
            try session.imagePaste.requireAvailable()
            guard !urls.isEmpty else { throw CloudImagePasteError.tooManyImages }
            guard urls.count <= 8 else { throw CloudImagePasteError.tooManyImages }
            let reader = CloudClipboardImageReader()
            for url in urls {
                let image = try await reader.read(url)
                try Task.checkCancellation()
                try await session.imagePaste.paste(image, generation: generation)
            }
            _ = operation.finish()
        } catch is CancellationError {
            if cleansUpTransferredFiles, !ownsPreparation { pasteboard.cleanupTransferredTemporaryImageFiles(urls) }
            _ = operation.cancel()
            throw CancellationError()
        } catch {
            if cleansUpTransferredFiles, !ownsPreparation { pasteboard.cleanupTransferredTemporaryImageFiles(urls) }
            _ = operation.finish()
            presentCloudImagePasteFailure(error)
            throw error
        }
    }

    /// Checks that every image of a composer submit can be sent before any of
    /// the submit reaches the terminal, so a refused image does not leave the
    /// text before it already typed and duplicated by a retry.
    @MainActor
    func validateCloudImagesForSubmit(_ urls: [URL]) throws {
        do {
            guard let session = hostedView.cloudTerminalOverlay.session else {
                throw CloudImagePasteError.unavailable
            }
            guard ManagedFileTransferPolicy.isEnabled else {
                throw ManagedFileTransferPolicy.refusalError()
            }
            try session.imagePaste.requireAvailable()
            for url in urls { try CloudClipboardImage.validateFile(at: url) }
        } catch {
            presentCloudImagePasteFailure(error)
            throw error
        }
    }

    @MainActor
    private func presentCloudImagePasteFailure(_ error: Error) {
        if ManagedFileTransferPolicy.isRefusal(error) {
            ManagedFileTransferPolicy.presentRefusal()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "cloud.imagePaste.failed", defaultValue: "Image could not be pasted")
        alert.informativeText = (error as? CloudImagePasteError ?? .unavailable).localizedMessage
        if let window = hostedView.window { alert.beginSheetModal(for: window) }
        else { NSSound.beep() }
    }
}
