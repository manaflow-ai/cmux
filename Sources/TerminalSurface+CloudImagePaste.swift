import AppKit
import CmuxCloudImagePaste
import CmuxTerminal

extension TerminalSurface {
    /// Runs only for a managed Cloud paste plan; there is deliberately no text fallback.
    @MainActor
    func pasteCloudImages(
        _ urls: [URL],
        operation: TerminalImageTransferOperation = TerminalImageTransferOperation()
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
                pasteboard.cleanupTransferredTemporaryImageFiles(urls)
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
            if !ownsPreparation { pasteboard.cleanupTransferredTemporaryImageFiles(urls) }
            _ = operation.cancel()
            throw CancellationError()
        } catch {
            if !ownsPreparation { pasteboard.cleanupTransferredTemporaryImageFiles(urls) }
            _ = operation.finish()
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
