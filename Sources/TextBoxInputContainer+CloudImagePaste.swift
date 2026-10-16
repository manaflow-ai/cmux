import CmuxCloud
import AppKit
import CmuxCloudImagePaste

extension TextBoxInputContainer {
    /// A composer must never submit a Mac path or send an attachment before Submit.
    func refuseCloudComposerImage() {
        let alert = NSAlert()
        alert.messageText = String(localized: "cloud.imagePaste.failed", defaultValue: "Image could not be pasted")
        alert.informativeText = CloudImagePasteError.useTerminal.localizedMessage
        if let window = surface.hostedView.window { alert.beginSheetModal(for: window) }
        else { NSSound.beep() }
    }
    func attachFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return false }

        Task { @MainActor [self, weak textView] in
            guard let textView else { return }
            let runtimeGeneration = self.surface.runtimeSurfaceGeneration
            let target = await self.surface.resolvedImageTransferTargetAsync()
            guard self.surface.runtimeSurfaceGeneration == runtimeGeneration,
                  self.ownsTextView(textView) else { return }
            _ = self.attachFileURLs(
                standardizedURLs,
                into: textView,
                target: target
            )
        }
        return true
    }

    @MainActor
    private func attachFileURLs(
        _ fileURLs: [URL],
        into textView: TextBoxInputTextView,
        target: TerminalImageTransferTarget
    ) -> Bool {

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: fileURLs,
            target: target,
            mode: .paste
        )

        switch plan {
        case .insertText, .insertTextSegments:
            textView.insertAttachments(
                fileURLs.map {
                        TextBoxAttachment(
                            localURL: $0,
                            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0),
                            cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed($0)
                        )
                }
            )
            attachments = textView.inlineAttachments()
            text = textView.plainText()
            return true
        case .uploadFiles(let uploadURLs, let remoteTarget):
            uploadFileAttachments(uploadURLs, remoteTarget: remoteTarget, focusing: textView)
            return true
        case .pasteCloudImages:
            refuseCloudComposerImage()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
            return true
        case .reject:
            return false
        }
    }

}
