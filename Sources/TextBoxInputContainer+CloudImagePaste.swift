import AppKit

extension TextBoxInputContainer {
    /// A composer must never submit a Mac path or send an attachment before Submit.
    func refuseCloudComposerImage() {
        let alert = NSAlert()
        alert.messageText = String(localized: "cloud.imagePaste.failed", defaultValue: "Image could not be pasted")
        alert.informativeText = CloudImagePasteError.useTerminal.localizedDescription
        if let window = surface.hostedView.window { alert.beginSheetModal(for: window) }
        else { NSSound.beep() }
    }
    func attachFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !standardizedURLs.isEmpty else { return false }

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: standardizedURLs,
            target: surface.resolvedImageTransferTarget(),
            mode: .paste
        )

        switch plan {
        case .insertText, .insertTextSegments:
            textView.insertAttachments(
                standardizedURLs.map {
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
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(standardizedURLs)
            return true
        case .reject:
            return false
        }
    }

}
