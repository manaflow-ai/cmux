import AppKit
import Foundation

/// The TextBox composer subsystem for ``TerminalPanel``: activation, focus arbitration
/// with the terminal surface, escape handling, draft preservation/restoration, and the
/// DEBUG-only inline fixture.
extension TerminalPanel {
    func recordTextBoxLaunchCommand(_ command: String) {
        guard let boundedContext = TextBoxAgentDetection.boundedLaunchCommandContext(from: command) else { return }
        textBoxState.recordLaunchCommand(boundedContext)
    }

    func clearTextBoxLaunchCommand() {
        textBoxState.clearLaunchCommand()
    }

    func preferTextBoxInputWhenActivated() {
        isTextBoxActive = true
        textBoxInputFocusIntent = .textBox
        shouldFocusTextBoxWhenAvailable = true
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        focusTextBoxIfNeeded()
    }

    func showTextBoxInputWhenAvailable() {
        isTextBoxActive = true
        textBoxInputFocusIntent = .terminal
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
    }

    func registerTextBoxInputView(_ view: TextBoxInputTextView) {
        textBoxInputView = view
        // Registration runs from NSViewRepresentable.makeNSView; restoring drafts here must not
        // write SwiftUI/Combine bindings while SwiftUI is constructing the subtree.
        if let restoredTextBoxDraft {
            self.restoredTextBoxDraft = nil
            view.installSessionDraft(restoredTextBoxDraft, notifyingTextChange: false)
        } else if let preservedTextBoxAttributedContent {
            self.preservedTextBoxAttributedContent = nil
            view.installPreservedContent(preservedTextBoxAttributedContent, notifyingTextChange: false)
        }
        focusTextBoxIfNeeded()
#if DEBUG
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
#endif
    }

    func textBoxInputViewDidMoveToWindow(_ view: TextBoxInputTextView) {
        guard textBoxInputView === view else { return }
        focusTextBoxIfNeeded()
#if DEBUG
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
#endif
    }

    @discardableResult
    func toggleTextBoxInput() -> Bool {
        if isTextBoxActive {
            hideTextBoxInput()
            return true
        }

        return focusTextBoxInput()
    }

    @discardableResult
    func focusTextBoxInputOrTerminal() -> Bool {
        if isTextBoxActive,
           textBoxInputFocusIntent == .textBox {
            shouldHideTextBoxOnNextEscape = false
            let didFocusTerminal = focusTerminalSurface(respectForeignFirstResponder: false)
            if !didFocusTerminal {
                textBoxInputFocusIntent = .textBox
            }
            return didFocusTerminal
        }

        return focusTextBoxInput()
    }

    @discardableResult
    func attachFileToTextBoxInput() -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true
        shouldOpenTextBoxFilePickerWhenAvailable = true
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        let didFocusTextBox = focusTextBoxIfNeeded()
        return didFocusTextBox || !hasMountedTextBox
    }

    func textBoxDidBecomeFocused() {
        shouldHideTextBoxOnNextEscape = false
        isTextBoxActive = true
        textBoxInputFocusIntent = .textBox
        surface.setFocus(false)
        hostedView.setActive(false)
    }

    func terminalDidBecomeFocused() {
        guard isTextBoxActive else { return }
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        textBoxInputFocusIntent = .terminal
    }

    func handleTextBoxEscape() {
        let hadTextBoxView = textBoxInputView != nil
        let didFocusTerminal = focusTerminalSurface(
            respectForeignFirstResponder: false,
            clearTextBoxHideArm: false
        )
        shouldHideTextBoxOnNextEscape = isTextBoxActive && (hadTextBoxView || didFocusTerminal)
    }

    @discardableResult
    func consumeTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard isTextBoxActive,
              shouldHideTextBoxOnNextEscape else {
            return false
        }
        guard textBoxOrSurfaceOwnsEscapeContext(in: window) else {
            shouldHideTextBoxOnNextEscape = false
            return false
        }
        hideTextBoxInput()
        return true
    }

    func clearTextBoxHideEscapeArm() {
        shouldHideTextBoxOnNextEscape = false
    }

    private func hideTextBoxInput() {
        shouldHideTextBoxOnNextEscape = false
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        textBoxInputFocusIntent = .hidden
        preserveTextBoxContentFromView()
        isTextBoxActive = false
        textBoxInputView = nil
        focusTerminalSurface(respectForeignFirstResponder: false)
    }

    private func preserveTextBoxContentFromView() {
        guard let textBoxInputView else { return }
        preserveTextBoxContentForUnmount(from: textBoxInputView)
    }

    func preserveTextBoxContentForUnmount(from textBoxInputView: TextBoxInputTextView) {
        // Dismantle can run while AttributeGraph is destroying this subtree. Cache only
        // non-published draft state here; normal editing keeps the published bindings current.
        if isClosingPanel {
            assert(
                didDiscardTextBoxContentForClose,
                "close() must discard TextBox content before SwiftUI dismantles the TextBox view"
            )
            recordTextBoxViewUnmounted(textBoxInputView)
            return
        }
        let preservedContent = textBoxInputView.attributedContentForPreservation()
        textBoxInputView.invalidatePendingAttachmentUploads()
        preservedTextBoxAttributedContent = NSAttributedString(
            attributedString: preservedContent
        )
        recordTextBoxViewUnmounted(textBoxInputView)
    }

    private func recordTextBoxViewUnmounted(_ textBoxInputView: TextBoxInputTextView) {
        guard self.textBoxInputView === textBoxInputView else { return }
        self.textBoxInputView = nil
    }

    func discardTextBoxContentForClose(from textBoxInputView: TextBoxInputTextView? = nil) {
        didDiscardTextBoxContentForClose = true
        let currentTextView = textBoxInputView ?? self.textBoxInputView
        let attachmentsToCleanup = currentTextView?.inlineAttachments() ?? textBoxAttachments
        if let currentTextView {
            currentTextView.clearContent(cleanupAttachmentFiles: true)
            currentTextView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
        } else if !attachmentsToCleanup.isEmpty {
            let cleanupTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            cleanupTextView.cleanupDisposableAttachmentFiles(
                attachmentsToCleanup,
                preservingActiveInlineAttachments: false
            )
        }
        restoredTextBoxDraft = nil
        preservedTextBoxAttributedContent = nil
        textBoxContent = ""
        textBoxAttachments = []
        isTextBoxActive = false
        textBoxInputFocusIntent = .hidden
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        if self.textBoxInputView === currentTextView {
            self.textBoxInputView = nil
        }
    }

    func sessionTextBoxDraftSnapshot() -> SessionTextBoxInputDraftSnapshot? {
        if let textBoxInputView {
            return textBoxInputView.sessionDraftSnapshot(isActive: isTextBoxActive)
        }

        if let restoredTextBoxDraft {
            return restoredTextBoxDraft
        }

        if let preservedTextBoxAttributedContent {
            return TextBoxInputTextView.sessionDraftSnapshot(
                from: preservedTextBoxAttributedContent,
                isActive: isTextBoxActive
            )
        }

        return TextBoxInputTextView.sessionDraftSnapshot(
            text: textBoxContent,
            attachments: textBoxAttachments,
            isActive: isTextBoxActive
        )
    }

    func restoreSessionTextBoxDraft(_ draft: SessionTextBoxInputDraftSnapshot?) {
        guard let draft,
              !draft.parts.isEmpty else {
            restoredTextBoxDraft = nil
            preservedTextBoxAttributedContent = nil
            textBoxContent = ""
            textBoxAttachments = []
            isTextBoxActive = false
            textBoxInputFocusIntent = .hidden
            shouldFocusTextBoxWhenAvailable = false
            shouldOpenTextBoxFilePickerWhenAvailable = false
            shouldHideTextBoxOnNextEscape = false
            return
        }

        restoredTextBoxDraft = draft
        preservedTextBoxAttributedContent = nil
        textBoxContent = TextBoxInputTextView.plainText(from: draft)
        textBoxAttachments = TextBoxInputTextView.attachments(from: draft)
        isTextBoxActive = draft.isActive
        textBoxInputFocusIntent = draft.isActive ? .textBox : .hidden
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
    }

    @discardableResult
    private func focusTextBoxIfNeeded() -> Bool {
        guard shouldFocusTextBoxWhenAvailable,
              isTextBoxActive,
              let textBoxInputView,
              let window = textBoxInputView.window else { return false }
        guard window.makeFirstResponder(textBoxInputView) else { return false }
        shouldFocusTextBoxWhenAvailable = false
        textBoxInputFocusIntent = .textBox
        surface.setFocus(false)
        hostedView.setActive(false)
        if shouldOpenTextBoxFilePickerWhenAvailable {
            shouldOpenTextBoxFilePickerWhenAvailable = false
            textBoxInputView.openFilePicker()
        }
        return true
    }

    @discardableResult
    func focusTextBoxInput() -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        let didFocusTextBox = focusTextBoxIfNeeded()
        return didFocusTextBox || !hasMountedTextBox
    }

    func textBoxOwnsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder,
              let textBoxInputView else { return false }
        if responder === textBoxInputView {
            return true
        }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: textBoxInputView)
    }

    private func textBoxOrSurfaceOwnsResponder(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === hostedView.window,
           hostedView.isSurfaceViewFirstResponder() {
            return true
        }
        guard let responder = window.firstResponder else { return false }
        if textBoxOwnsResponder(responder) {
            return true
        }
        return hostedView.ownedPanelFocusIntent(for: responder) == .surface
    }

    private func textBoxOrSurfaceOwnsEscapeContext(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return textBoxOrSurfaceOwnsResponder(in: window)
    }

#if DEBUG
    @discardableResult
    func installDebugTextBoxInlineFixture(
        localURL: URL?,
        beforeText: String,
        afterText: String
    ) -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true

        let fixture = DebugTextBoxInlineFixture(
            localURL: localURL?.standardizedFileURL,
            beforeText: beforeText,
            afterText: afterText
        )

        pendingDebugTextBoxInlineFixture = fixture
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
        return true
    }

    private func applyPendingDebugTextBoxInlineFixtureIfNeeded() {
        guard let fixture = pendingDebugTextBoxInlineFixture,
              let textBoxInputView,
              let textBoxWindow = textBoxInputView.window,
              textBoxWindow === hostedView.window else { return }
        pendingDebugTextBoxInlineFixture = nil
        applyDebugTextBoxInlineFixture(fixture, to: textBoxInputView)
    }

    private func applyDebugTextBoxInlineFixture(
        _ fixture: DebugTextBoxInlineFixture,
        to textBoxInputView: TextBoxInputTextView
    ) {
        textBoxInputView.window?.makeFirstResponder(textBoxInputView)
        let attachment = fixture.localURL.map {
                TextBoxAttachment(
                    localURL: $0,
                    submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0)
                )
        }
        textBoxContent = fixture.beforeText + fixture.afterText
        textBoxAttachments = attachment.map { [$0] } ?? []
        textBoxInputView.installInlineControlFixture(
            attachment,
            beforeText: fixture.beforeText,
            afterText: fixture.afterText
        )
        textBoxContent = textBoxInputView.plainText()
        textBoxAttachments = textBoxInputView.inlineAttachments()
    }
#endif
}
