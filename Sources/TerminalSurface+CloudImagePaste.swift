import AppKit
import CmuxTerminal

extension TerminalSurface {
    /// Runs only for a managed Cloud paste plan; there is deliberately no text fallback.
    @MainActor
    func pasteCloudImages(
        _ urls: [URL],
        operation: TerminalImageTransferOperation = TerminalImageTransferOperation(),
        onCancel: @escaping () -> Void,
        onCompletion: @escaping () -> Void = {}
    ) {
        let pasteboard = GhosttyApp.terminalPasteboard
        let session = hostedView.cloudTerminalOverlay.session
        let generation: UUID
        do {
            guard let session else { throw CloudImagePasteError.unavailable }
            generation = try session.imagePaste.beginPreparation()
        } catch {
            _ = operation.finish()
            pasteboard.cleanupTransferredTemporaryImageFiles(urls)
            presentCloudImagePasteFailure(error)
            onCompletion()
            return
        }
        hostedView.beginImageTransferIndicator(for: operation, onCancel: onCancel)
        let task = Task { @MainActor [weak self, weak session] in
            defer {
                session?.imagePaste.endPreparation()
                pasteboard.cleanupTransferredTemporaryImageFiles(urls)
                self?.hostedView.endImageTransferIndicator(for: operation)
                onCompletion()
            }
            do {
                try Task.checkCancellation()
                guard ManagedFileTransferPolicy.isEnabled else { throw ManagedFileTransferPolicy.refusalError() }
                guard let session else { throw CloudImagePasteError.unavailable }
                try session.imagePaste.requireAvailable()
                guard !urls.isEmpty, urls.count <= 8 else { throw CloudImagePasteError.capacity }
                let reader = CloudClipboardImageReader()
                for url in urls {
                    let image = try await reader.read(url)
                    try Task.checkCancellation()
                    try await session.imagePaste.paste(image, generation: generation)
                }
                _ = operation.finish()
            } catch is CancellationError {
                _ = operation.cancel()
            } catch {
                _ = operation.finish()
                self?.presentCloudImagePasteFailure(error)
            }
        }
        operation.installCancellationHandler { task.cancel() }
    }

    @MainActor
    private func presentCloudImagePasteFailure(_ error: Error) {
        if ManagedFileTransferPolicy.isRefusal(error) {
            ManagedFileTransferPolicy.presentRefusal()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "cloud.imagePaste.failed", defaultValue: "Image could not be pasted")
        alert.informativeText = (error as? CloudImagePasteError ?? .unavailable).localizedDescription
        if let window = hostedView.window { alert.beginSheetModal(for: window) }
        else { NSSound.beep() }
    }
}
