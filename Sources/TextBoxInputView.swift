import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - NSViewRepresentable Bridge
struct TextBoxInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var attachments: [TextBoxAttachment]
    @Binding var textViewHeight: CGFloat
    @Binding var hasPendingAttachmentUpload: Bool
    let font: NSFont
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let terminalTitle: String
    let completionRootDirectory: String?
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onFocusTextBox: () -> Void
    let onToggleFocus: () -> Void
    let onForwardText: (String, Bool) -> Void
    let onForwardKey: (TextBoxTerminalKey) -> Void
    let onForwardControl: (String) -> Void
    let onPaste: (NSPasteboard, TextBoxInputTextView) -> Bool
    let onInsertFileURLs: ([URL], TextBoxInputTextView) -> Bool
    let onChooseFiles: () -> Void
    let onContentChanged: () -> Void
    let onMarkedTextStateChanged: (Bool) -> Void
    let onTextViewCreated: (TextBoxInputTextView) -> Void
    let onTextViewMovedToWindow: (TextBoxInputTextView) -> Void
    let onTextViewDismantled: (TextBoxInputTextView) -> Void

    init(
        text: Binding<String>,
        attachments: Binding<[TextBoxAttachment]>,
        textViewHeight: Binding<CGFloat>,
        hasPendingAttachmentUpload: Binding<Bool>,
        font: NSFont,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        terminalTitle: String,
        completionRootDirectory: String?,
        onSubmit: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onFocusTextBox: @escaping () -> Void,
        onToggleFocus: @escaping () -> Void,
        onForwardText: @escaping (String, Bool) -> Void,
        onForwardKey: @escaping (TextBoxTerminalKey) -> Void,
        onForwardControl: @escaping (String) -> Void,
        onPaste: @escaping (NSPasteboard, TextBoxInputTextView) -> Bool,
        onInsertFileURLs: @escaping ([URL], TextBoxInputTextView) -> Bool,
        onChooseFiles: @escaping () -> Void,
        onContentChanged: @escaping () -> Void,
        onMarkedTextStateChanged: @escaping (Bool) -> Void = { _ in },
        onTextViewCreated: @escaping (TextBoxInputTextView) -> Void,
        onTextViewMovedToWindow: @escaping (TextBoxInputTextView) -> Void,
        onTextViewDismantled: @escaping (TextBoxInputTextView) -> Void
    ) {
        self._text = text
        self._attachments = attachments
        self._textViewHeight = textViewHeight
        self._hasPendingAttachmentUpload = hasPendingAttachmentUpload
        self.font = font
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.terminalTitle = terminalTitle
        self.completionRootDirectory = completionRootDirectory
        self.onSubmit = onSubmit
        self.onEscape = onEscape
        self.onFocusTextBox = onFocusTextBox
        self.onToggleFocus = onToggleFocus
        self.onForwardText = onForwardText
        self.onForwardKey = onForwardKey
        self.onForwardControl = onForwardControl
        self.onPaste = onPaste
        self.onInsertFileURLs = onInsertFileURLs
        self.onChooseFiles = onChooseFiles
        self.onContentChanged = onContentChanged
        self.onMarkedTextStateChanged = onMarkedTextStateChanged
        self.onTextViewCreated = onTextViewCreated
        self.onTextViewMovedToWindow = onTextViewMovedToWindow
        self.onTextViewDismantled = onTextViewDismantled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TextBoxInputTextView()
        textView.delegate = context.coordinator
        textView.onMoveToWindow = onTextViewMovedToWindow
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: TextBoxLayout.minimumTextHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 1, height: TextBoxLayout.minimumTextHeight)
        )
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = TextBoxLayout.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        updateTextView(textView, context: context)
        onTextViewCreated(textView)
        context.coordinator.queuePendingAttachmentUploadStateSync(from: textView)
        context.coordinator.queuePendingMarkedTextStateSync(from: textView)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? TextBoxInputTextView else { return }
        coordinator.parent.onTextViewDismantled(textView)
        textView.onMoveToWindow = { _ in }
        textView.onLayoutCompleted = { _ in }
        textView.invalidatePendingAttachmentUploads()
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TextBoxInputTextView else { return }
        textView.onMoveToWindow = onTextViewMovedToWindow
        let contentSize = scrollView.contentView.bounds.size
        if contentSize.width > 0 {
            textView.frame.size.width = contentSize.width
            textView.textContainer?.containerSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        if shouldSynchronizeExternalTextToTextBox(
            inlineAttachmentCount: textView.inlineAttachments().count,
            plainText: textView.plainText(),
            externalText: text,
            hasMarkedText: textView.hasMarkedText()
        ) {
            textView.string = text
        }
        updateTextView(textView, context: context)
    }

    private func updateTextView(_ textView: TextBoxInputTextView, context: Context) {
        let coordinator = context.coordinator
        textView.font = font
        textView.textColor = foregroundColor
        textView.backgroundColor = .clear
        textView.insertionPointColor = foregroundColor
        textView.terminalTitle = terminalTitle
        textView.completionRootDirectory = completionRootDirectory
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onFocusTextBox = onFocusTextBox
        textView.onToggleFocus = onToggleFocus
        textView.onForwardText = onForwardText
        textView.onForwardKey = onForwardKey
        textView.onForwardControl = onForwardControl
        textView.onPaste = onPaste
        textView.onInsertFileURLs = onInsertFileURLs
        textView.onChooseFiles = onChooseFiles
        textView.onMarkedTextStateChanged = { [weak coordinator, weak textView] hasMarkedText in
            coordinator?.noteMarkedTextStateChanged(hasMarkedText, from: textView)
        }
        textView.refreshInlineAttachmentCells(font: font, foregroundColor: foregroundColor)
        textView.recenterSingleLineTextContainer()
        textView.wantsLayer = true
        textView.layer?.backgroundColor = NSColor.clear.cgColor
        textView.layer?.borderWidth = 0
        textView.delegate = context.coordinator
        textView.onLayoutCompleted = { [weak coordinator] textView in
            coordinator?.recalculateHeight(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextBoxInputView
        private var pendingAttachmentUploadStateForNextLayout: Bool?
        private var pendingMarkedTextStateForNextLayout: Bool?
        private var deliveredMarkedTextState: Bool?

        init(parent: TextBoxInputView) {
            self.parent = parent
        }

        /// Captures pending-upload state once after representable construction restores AppKit storage.
        func queuePendingAttachmentUploadStateSync(from textView: TextBoxInputTextView) {
            pendingAttachmentUploadStateForNextLayout = textView.hasPendingAttachmentUploadPlaceholder()
        }

        func queuePendingMarkedTextStateSync(from textView: TextBoxInputTextView) {
            pendingMarkedTextStateForNextLayout = textView.hasMarkedText()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TextBoxInputTextView else { return }
            textView.normalizeTextBaselineOffsets()
            publishTextViewContent(textView)
            noteMarkedTextStateChanged(textView.hasMarkedText(), from: textView)
            if parent.text.isEmpty,
               parent.attachments.isEmpty,
               !textView.hasPendingAttachmentUploadPlaceholder() {
                textView.invalidatePendingAttachmentUploads()
            }
            if !textView.isHandlingDidChangeText {
                textView.refreshMentionCompletions()
            }
            recalculateHeight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? TextBoxInputTextView else { return }
            noteMarkedTextStateChanged(textView.hasMarkedText(), from: textView)
            let color = textView.textColor ?? .labelColor
            textView.layer?.borderColor = color.withAlphaComponent(
                textView.window?.firstResponder === textView ? 0.45 : 0.24
            ).cgColor
            textView.refreshInlineAttachmentFocus()
            if !textView.isHandlingDidChangeText {
                textView.refreshMentionCompletions()
            }
        }

        func noteMarkedTextStateChanged(_ hasMarkedText: Bool, from textView: TextBoxInputTextView? = nil) {
            let pendingMarkedTextState = pendingMarkedTextStateForNextLayout
            if textView != nil {
                pendingMarkedTextStateForNextLayout = nil
            }
            if !hasMarkedText,
               let textView,
               deliveredMarkedTextState == true || pendingMarkedTextState == true {
                publishTextViewContent(textView)
            }
            if deliveredMarkedTextState != hasMarkedText {
                parent.onMarkedTextStateChanged(hasMarkedText)
            }
            deliveredMarkedTextState = hasMarkedText
        }

        private func publishTextViewContent(_ textView: TextBoxInputTextView) {
            let nextText = textView.plainText()
            let nextAttachments = textView.inlineAttachments()
            let nextHasPendingAttachmentUpload = textView.hasPendingAttachmentUploadPlaceholder()
            let contentChanged = parent.text != nextText
                || parent.attachments.map(\.id) != nextAttachments.map(\.id)
                || parent.hasPendingAttachmentUpload != nextHasPendingAttachmentUpload
            parent.text = nextText
            parent.attachments = nextAttachments
            parent.hasPendingAttachmentUpload = nextHasPendingAttachmentUpload
            if contentChanged {
                parent.onContentChanged()
            }
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            if let textBoxView = textView as? TextBoxInputTextView {
                textBoxView.recenterSingleLineTextContainer()
                applyPendingAttachmentUploadStateSyncIfNeeded()
                applyPendingMarkedTextStateSyncIfNeeded()
            }
            layoutManager.ensureLayout(for: textContainer)
            let lineFragmentCount = (textView as? TextBoxInputTextView)?.visualLineFragmentCount()
                ?? TextBoxInputTextView.visualLineFragmentCount(
                    textView: textView,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
            let preferredHeight: CGFloat

            if lineFragmentCount <= TextBoxLayout.minLines {
                let font = textView.font ?? parent.font
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                preferredHeight = max(
                    TextBoxLayout.minimumTextHeight,
                    lineHeight + TextBoxLayout.textInset.height * 2
                )
            } else {
                let font = textView.font ?? parent.font
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                let lineSpacing = CGFloat(max(0, lineFragmentCount - 1)) * TextBoxLayout.lineSpacing
                let inset = TextBoxLayout.textInset(forLineCount: lineFragmentCount)
                let usedRect = layoutManager.usedRect(for: textContainer)
                preferredHeight = ceil(
                    max(
                        usedRect.height,
                        lineHeight * CGFloat(lineFragmentCount) + lineSpacing
                    ) + inset.height * 2
                )
            }

            if abs(textView.frame.height - preferredHeight) > 0.5 {
                textView.frame.size.height = preferredHeight
            }
            if abs(parent.textViewHeight - preferredHeight) > 0.5 {
                parent.textViewHeight = preferredHeight
            }
        }

        /// Applies the one-shot pending-upload state captured during representable construction.
        private func applyPendingAttachmentUploadStateSyncIfNeeded() {
            // Silent restore skips textDidChange to avoid publishing through TerminalPanel while
            // SwiftUI constructs the representable. Layout completion is the post-construction
            // bridge point that keeps this binding aligned without mutating state from makeNSView.
            guard let hasPendingUpload = pendingAttachmentUploadStateForNextLayout else { return }
            pendingAttachmentUploadStateForNextLayout = nil
            guard parent.hasPendingAttachmentUpload != hasPendingUpload else { return }
            parent.hasPendingAttachmentUpload = hasPendingUpload
        }

        /// Applies the one-shot marked-text state captured during representable construction.
        private func applyPendingMarkedTextStateSyncIfNeeded() {
            guard let hasMarkedText = pendingMarkedTextStateForNextLayout else { return }
            pendingMarkedTextStateForNextLayout = nil
            noteMarkedTextStateChanged(hasMarkedText)
        }
    }
}

