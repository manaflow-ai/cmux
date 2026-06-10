import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Input Container View
@MainActor
private final class TextBoxInputViewReference {
    weak var textView: TextBoxInputTextView?
    var filePanelFocusRestorer: TextBoxFilePanelFocusRestorer?
}

final class TextBoxFilePanelFocusRestorer {
    private weak var textView: TextBoxInputTextView?
    private weak var parentWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(textView: TextBoxInputTextView) {
        self.textView = textView
        self.parentWindow = textView.window
    }

    deinit {
        invalidate()
    }

    func install(parentWindow: NSWindow) {
        invalidate()
        self.parentWindow = parentWindow

        let notificationCenter = NotificationCenter.default
        observers = [
            notificationCenter.addObserver(
                forName: NSWindow.didEndSheetNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.restoreFocusAndInvalidate()
            },
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.restoreFocusAndInvalidate()
            }
        ]
    }

    @discardableResult
    func restoreFocusNow() -> Bool {
        guard let textView,
              let window = textView.window ?? parentWindow else {
            return false
        }
        return window.makeFirstResponder(textView)
    }

    func invalidate() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll(keepingCapacity: false)
    }

    private func restoreFocusAndInvalidate() {
        restoreFocusNow()
        invalidate()
    }
}

private struct TextBoxInputGlassPillBackground: View {
    let foreground: Color
    let fallbackTint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TextBoxLayout.pillCornerRadius, style: .continuous)

#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            shape
                .fill(Color.clear)
                .glassEffect(.regular.interactive(true), in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.24), lineWidth: 0.85)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        } else {
            fallback(shape)
        }
#else
        fallback(shape)
#endif
    }

    @ViewBuilder
    private func fallback(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(.regularMaterial)
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            fallbackTint.opacity(0.20),
                            Color.black.opacity(0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.34),
                            foreground.opacity(0.16),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct TextBoxSendButtonStyle: ButtonStyle {
    let canSend: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed && canSend ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard canSend else {
            return Color.white.opacity(0.18)
        }
        return isPressed ? Color.white.opacity(0.68) : Color.white
    }
}

private struct TextBoxAttachmentChip: View {
    let attachment: TextBoxAttachment
    let foreground: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: TextBoxLayout.attachmentImageSize,
                        height: TextBoxLayout.attachmentImageSize
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 12, weight: .medium))
                    .frame(
                        width: TextBoxLayout.attachmentImageSize,
                        height: TextBoxLayout.attachmentImageSize
                    )
            }

            Text(attachment.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 118, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(foreground.opacity(0.62))
            .help(String(localized: "textbox.removeAttachment.tooltip", defaultValue: "Remove Attachment"))
            .accessibilityLabel(String(localized: "textbox.removeAttachment.tooltip", defaultValue: "Remove Attachment"))
        }
        .foregroundStyle(foreground.opacity(0.88))
        .padding(.leading, 0)
        .padding(.trailing, 4)
        .frame(height: TextBoxLayout.attachmentChipHeight)
        .background(
            Capsule(style: .continuous)
                .fill(foreground.opacity(0.10))
        )
    }
}

struct TextBoxInputContainer: View {
    @Binding var text: String
    @Binding var attachments: [TextBoxAttachment]
    let surface: TerminalSurface
    let terminalBackgroundColor: NSColor
    let terminalForegroundColor: NSColor
    let terminalFont: NSFont
    let maxLines: Int
    let terminalAgentContext: String
    let onFocusTextBox: () -> Void
    let onToggleFocus: () -> Void
    let onEscape: () -> Void
    let onTextViewCreated: (TextBoxInputTextView) -> Void
    let onTextViewMovedToWindow: (TextBoxInputTextView) -> Void
    let onTextViewDismantled: (TextBoxInputTextView) -> Void

    @State private var textViewHeight: CGFloat = 0
    @State private var hasPendingAttachmentUpload = false
    @State private var hasMarkedText = false
    @State private var textViewReference = TextBoxInputViewReference()
    @State private var contentRevision: UInt64 = 0

    private var textFont: NSFont {
        NSFont.systemFont(ofSize: max(14, terminalFont.pointSize + 2), weight: .regular)
    }

    private func heightForLines(_ lines: Int) -> CGFloat {
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading)
        let lineSpacing = CGFloat(max(0, lines - 1)) * TextBoxLayout.lineSpacing
        let inset = TextBoxLayout.textInset(forLineCount: lines)
        return lineHeight * CGFloat(lines) + lineSpacing + inset.height * 2
    }

    private var completionRootDirectory: String? {
        guard let workspace = surface.owningWorkspace() else { return nil }
        if let directory = workspace.panelDirectories[surface.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        if let directory = workspace.terminalPanel(for: surface.id)?
            .requestedWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            return directory
        }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }

    var body: some View {
        let minHeight = max(TextBoxLayout.minimumTextHeight, heightForLines(TextBoxLayout.minLines))
        let maxHeight = heightForLines(max(TextBoxLayout.minLines, maxLines))
        let clampedHeight = max(minHeight, min(maxHeight, textViewHeight))
        let foreground = Color(nsColor: terminalForegroundColor)
        let background = Color(nsColor: terminalBackgroundColor)
        let canSend = shouldEnableTextBoxSubmit(
            text: text,
            attachmentCount: attachments.count,
            hasPendingAttachmentUpload: hasPendingAttachmentUpload,
            hasMarkedText: hasMarkedText
        )

        HStack(alignment: .bottom, spacing: 6) {
            addFilesButton(foreground: foreground)
                .offset(x: TextBoxLayout.leadingButtonHorizontalOffset)
                .padding(.bottom, TextBoxLayout.buttonBottomPadding)

            ZStack(alignment: .leading) {
                TextBoxInputView(
                    text: $text,
                    attachments: $attachments,
                    textViewHeight: $textViewHeight,
                    hasPendingAttachmentUpload: $hasPendingAttachmentUpload,
                    font: textFont,
                    backgroundColor: terminalBackgroundColor,
                    foregroundColor: terminalForegroundColor,
                    terminalTitle: terminalAgentContext,
                    completionRootDirectory: completionRootDirectory,
                    onSubmit: submit,
                    onEscape: onEscape,
                    onFocusTextBox: onFocusTextBox,
                    onToggleFocus: onToggleFocus,
                    onForwardText: forwardText(_:focusTerminalAfterSend:),
                    onForwardKey: forwardKey(_:),
                    onForwardControl: forwardControl(_:),
                    onPaste: handlePaste(_:into:),
                    onInsertFileURLs: insertSelectedFileURLs(_:into:),
                    onChooseFiles: chooseFiles,
                    onContentChanged: markContentChanged,
                    onMarkedTextStateChanged: updateMarkedTextState(_:),
                    onTextViewCreated: registerTextView(_:),
                    onTextViewMovedToWindow: onTextViewMovedToWindow,
                    onTextViewDismantled: onTextViewDismantled
                )

                if shouldShowTextBoxPlaceholder(
                    text: text,
                    attachmentCount: attachments.count,
                    hasMarkedText: hasMarkedText
                ) {
                    Text(String(localized: "textbox.placeholder", defaultValue: "Prompt or command"))
                        .font(.system(size: textFont.pointSize))
                        .foregroundStyle(Color(nsColor: terminalForegroundColor).opacity(0.36))
                        .padding(.leading, TextBoxLayout.textInset.width)
                        .frame(height: clampedHeight, alignment: .center)
                        .offset(y: TextBoxLayout.placeholderVerticalOffset)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: clampedHeight)
            .frame(maxWidth: .infinity)

            sendButton(canSend: canSend, foreground: foreground)
                .offset(x: TextBoxLayout.trailingButtonHorizontalOffset)
                .padding(.bottom, TextBoxLayout.buttonBottomPadding)
        }
        .padding(.horizontal, TextBoxLayout.pillHorizontalPadding)
        .padding(.vertical, TextBoxLayout.pillVerticalPadding)
        .background(
            TextBoxInputGlassPillBackground(
                foreground: foreground,
                fallbackTint: background
            )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func addFilesButton(foreground: Color) -> some View {
        Button(action: chooseFiles) {
            Image(systemName: "plus")
                .font(.system(size: TextBoxLayout.iconSymbolSize, weight: .semibold))
                .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
                .background(
                    Circle()
                        .fill(foreground.opacity(0.10))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground.opacity(0.82))
        .help(String(localized: "textbox.addFiles.tooltip", defaultValue: "Add Files"))
        .accessibilityLabel(String(localized: "textbox.addFiles.tooltip", defaultValue: "Add Files"))
        .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
    }

    private func attachmentStrip(foreground: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(attachments) { attachment in
                    TextBoxAttachmentChip(
                        attachment: attachment,
                        foreground: foreground,
                        onRemove: {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    )
                }
            }
        }
        .frame(maxWidth: 280)
        .frame(height: TextBoxLayout.attachmentChipHeight)
    }

    private func sendButton(canSend: Bool, foreground: Color) -> some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: TextBoxLayout.sendSymbolSize, weight: .bold))
                .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
        }
        .buttonStyle(TextBoxSendButtonStyle(canSend: canSend))
        .foregroundStyle(canSend ? Color.black.opacity(0.86) : foreground.opacity(0.38))
        .help(String(localized: "textbox.send.tooltip", defaultValue: "Send"))
        .accessibilityLabel(String(localized: "textbox.send.tooltip", defaultValue: "Send"))
        .disabled(!canSend)
        .frame(width: TextBoxLayout.iconButtonSize, height: TextBoxLayout.iconButtonSize)
    }

    private func submit() {
        let textView = textViewReference.textView
        guard shouldSubmitTextBox(
            hasPendingAttachmentUpload: textView?.hasPendingAttachmentUploadPlaceholder() ?? hasPendingAttachmentUpload,
            hasMarkedText: textView?.hasMarkedText() ?? hasMarkedText
        ) else {
            NSSound.beep()
            return
        }

        let submittedParts = textView?.submissionParts()
            ?? [TextBoxSubmissionPart.text(text.trimmingCharacters(in: .newlines))]
        guard TextBoxSubmissionFormatter.hasSubmittableContent(submittedParts) else {
            NSSound.beep()
            return
        }
        let submittedTextView = textView
        let preservedContent = submittedTextView?.attributedContentForPreservation()
        submittedTextView?.prepareForSubmit()
        submittedTextView?.clearContent(cleanupAttachmentFiles: false)
        text = ""
        attachments = []
        hasPendingAttachmentUpload = false
        textViewHeight = 0
        let rollbackSnapshot = TextBoxFailedSubmitRollbackSnapshot(
            revision: advanceContentRevision(),
            text: "",
            attachmentCount: 0
        )
        TextBoxSubmit.send(
            submittedParts,
            via: surface,
            terminalAgentContext: terminalAgentContext
        ) { completionContext in
            guard completionContext.didSubmit else {
                guard TextBoxFailedSubmitRollbackPolicy.shouldRestore(
                    rollbackSnapshot: rollbackSnapshot,
                    currentSnapshot: currentRollbackSnapshot()
                ) else {
                    NSSound.beep()
                    return
                }
                if let preservedContent {
                    submittedTextView?.installPreservedContent(preservedContent)
                } else {
                    text = TextBoxSubmissionFormatter.formattedText(from: submittedParts)
                    attachments = submittedParts.compactMap { part in
                        if case .attachment(let attachment) = part { return attachment }
                        return nil
                    }
                }
                NSSound.beep()
                return
            }
            let submittedAttachments = submittedParts.compactMap { part -> TextBoxAttachment? in
                if case .attachment(let attachment) = part { return attachment }
                return nil
            }
            submittedTextView?.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions(submittedAttachments)
            let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: submittedParts,
                terminalAgentContext: terminalAgentContext,
                completionContext: completionContext
            )
            submittedTextView?.cleanupDisposableAttachmentFiles(cleanupAttachments)
        }
    }

    private func markContentChanged() {
        _ = advanceContentRevision()
    }

    private func updateMarkedTextState(_ nextValue: Bool) {
        guard hasMarkedText != nextValue else { return }
        hasMarkedText = nextValue
    }

    @discardableResult
    private func advanceContentRevision() -> UInt64 {
        contentRevision &+= 1
        return contentRevision
    }

    private func currentRollbackSnapshot() -> TextBoxFailedSubmitRollbackSnapshot {
        let currentTextView = textViewReference.textView
        return TextBoxFailedSubmitRollbackSnapshot(
            revision: contentRevision,
            text: currentTextView?.plainText() ?? text,
            attachmentCount: currentTextView?.inlineAttachments().count ?? attachments.count
        )
    }

    /// Records the newly constructed text view and lets the panel restore draft state.
    private func registerTextView(_ textView: TextBoxInputTextView) {
        textViewReference.textView = textView
        onTextViewCreated(textView)
    }

    private func chooseFiles() {
        guard let textView = textViewReference.textView else {
            NSSound.beep()
            return
        }

        focusTextViewAfterFilePanel(textView)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "textbox.addFiles.panel.title", defaultValue: "Add Files")
        panel.prompt = String(localized: "textbox.addFiles.panel.prompt", defaultValue: "Add")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            focusTextViewAfterFilePanel(textView)
            guard response == .OK else { return }
            if !insertSelectedFileURLs(panel.urls, into: textView) {
                NSSound.beep()
                focusTextViewAfterFilePanel(textView)
            }
        }

        if let window = textView.window {
            installFilePanelFocusRestorer(for: textView, parentWindow: window)
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    private func focusTextViewAfterFilePanel(_ textView: TextBoxInputTextView) {
        textView.window?.makeFirstResponder(textView)
    }

    private func installFilePanelFocusRestorer(for textView: TextBoxInputTextView, parentWindow: NSWindow) {
        let restorer = TextBoxFilePanelFocusRestorer(textView: textView)
        restorer.install(parentWindow: parentWindow)
        textViewReference.filePanelFocusRestorer = restorer
    }

    private func insertSelectedFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
        let standardizedURLs = fileURLs
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        return insertPreparedContent(.fileURLs(standardizedURLs), into: textView)
    }

    private func focusTerminal() {
        surface.hostedView.ensureFocus(for: surface.tabId, surfaceId: surface.id)
    }

    private func forwardText(_ text: String, focusTerminalAfterSend: Bool) {
        surface.sendInput(text)
        if focusTerminalAfterSend {
            focusTerminal()
        }
    }

    private func forwardKey(_ key: TextBoxTerminalKey) {
        _ = surface.sendNamedKey(key.rawValue)
    }

    private func forwardControl(_ key: String) {
        _ = surface.sendNamedKey("ctrl-\(key)")
    }

    private func handlePaste(_ pasteboard: NSPasteboard, into textView: TextBoxInputTextView) -> Bool {
        let preparedContent = TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste
        )
        return insertPreparedContent(preparedContent, into: textView)
    }

    private func insertPreparedContent(
        _ preparedContent: TerminalImageTransferPreparedContent,
        into textView: TextBoxInputTextView
    ) -> Bool {
        switch preparedContent {
        case .insertText(let insertedText):
            insertText(insertedText, into: textView)
            return true
        case .fileURLs(let fileURLs):
            return attachFileURLs(fileURLs, into: textView)
        case .reject:
            return false
        }
    }

    private func attachFileURLs(_ fileURLs: [URL], into textView: TextBoxInputTextView) -> Bool {
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
        case .reject:
            return false
        }
    }

    private func uploadFileAttachments(
        _ fileURLs: [URL],
        remoteTarget: TerminalRemoteUploadTarget,
        focusing textView: TextBoxInputTextView
    ) {
        let placeholderID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: placeholderID)
        let operation = TerminalImageTransferOperation()
        let uploadValidationToken = textView.pendingAttachmentUploadValidationToken()
        surface.hostedView.beginImageTransferIndicator(
            for: operation,
            onCancel: { _ = operation.cancel() }
        )

        let finish: (Result<[String], Error>) -> Void = { [weak surface] result in
            DispatchQueue.main.async {
                @MainActor func removePendingPlaceholder() {
                    guard textViewReference.textView === textView,
                          textView.removePendingAttachmentUploadPlaceholder(id: placeholderID) else {
                        return
                    }
                    attachments = textView.inlineAttachments()
                    text = textView.plainText()
                }

                surface?.hostedView.endImageTransferIndicator(for: operation)
                guard operation.finish() else {
                    removePendingPlaceholder()
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    return
                }

                switch result {
                case .success(let remotePaths):
                    guard !remotePaths.isEmpty else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        NSSound.beep()
                        return
                    }
                    let newAttachments = fileURLs.enumerated().compactMap { index, fileURL -> TextBoxAttachment? in
                        guard remotePaths.indices.contains(index) else { return nil }
                        return TextBoxAttachment(
                            localURL: fileURL,
                            submissionText: TextBoxAttachment.submissionText(forPath: remotePaths[index]),
                            submissionPath: remotePaths[index],
                            cleanupLocalURLWhenDisposed: true
                        )
                    }
                    guard !newAttachments.isEmpty else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        NSSound.beep()
                        return
                    }
                    guard textViewReference.textView === textView,
                          textView.canAcceptPendingAttachmentUpload(validationToken: uploadValidationToken) else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        return
                    }
                    guard textView.replacePendingAttachmentUploadPlaceholder(
                        id: placeholderID,
                        with: newAttachments
                    ) else {
                        removePendingPlaceholder()
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                        return
                    }
                    attachments = textView.inlineAttachments()
                    text = textView.plainText()
                case .failure:
                    removePendingPlaceholder()
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    NSSound.beep()
                }
            }
        }

        switch remoteTarget {
        case .workspaceRemote:
            guard let workspace = MainActor.assumeIsolated({
                surface.owningWorkspace()
            }) else {
                finish(.failure(NSError(domain: "cmux.textbox.attachment", code: 3)))
                return
            }
            workspace.uploadDroppedFilesForRemoteTerminal(
                fileURLs,
                operation: operation,
                completion: finish
            )
        case .detectedSSH(let session):
            session.uploadDroppedFiles(
                fileURLs,
                operation: operation,
                completion: finish
            )
        }
    }

    private func insertText(_ insertedText: String, into textView: TextBoxInputTextView) {
        textView.window?.makeFirstResponder(textView)
        textView.insertText(insertedText, replacementRange: textView.selectedRange())
    }
}

