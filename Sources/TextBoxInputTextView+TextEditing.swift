import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Responder, Text Editing & Layout
extension TextBoxInputTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidatePendingAttachmentUploads()
            dismissMentionCompletions()
        } else {
            notifyMovedToWindowIfAttached()
            if mentionCompletionPanel?.isVisible == true {
                scheduleMentionCompletionPanelReposition()
            }
        }
        layer?.borderColor = textColor?.withAlphaComponent(0.24).cgColor
    }

    private func notifyMovedToWindowIfAttached() {
        guard window != nil else { return }
        onMoveToWindow(self)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusTextBox()
            layer?.borderColor = textColor?.withAlphaComponent(0.45).cgColor
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            dismissMentionCompletions()
            layer?.borderColor = textColor?.withAlphaComponent(0.24).cgColor
            if preserveAttachmentFocusOnNextResign,
               isAttachmentPreviewShown,
               focusedAttachmentCharacterIndex != nil {
                preserveAttachmentFocusOnNextResign = false
                installAttachmentKeyDownMonitorIfNeeded()
            } else if !isAttachmentPreviewShown {
                preserveAttachmentFocusOnNextResign = false
                clearAttachmentFocus(dismissPreview: true)
                refreshInlineAttachmentFocus()
            } else {
                preserveAttachmentFocusOnNextResign = false
            }
        }
        return result
    }

    override func paste(_ sender: Any?) {
        if onPaste(.general, self) {
            refreshInlineAttachmentFocus()
            return
        }
        super.paste(sender)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
            return false
        }
        queueAutomaticAttachmentFileCleanup(in: affectedCharRange)
        return true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        queueAutomaticAttachmentFileCleanup(in: replacementRange)
        let isOuterInsertText = activeInsertTextDepth == 0
        if isOuterInsertText {
            didChangeTextDuringActiveInsertText = false
        }
        activeInsertTextDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        activeInsertTextDepth = max(0, activeInsertTextDepth - 1)
        let didChangeTextWasHandled = didChangeTextDuringActiveInsertText
        if isOuterInsertText {
            didChangeTextDuringActiveInsertText = false
        }
        if didChangeTextWasHandled {
            flushAutomaticAttachmentFileCleanup()
        } else {
            didChangeText()
        }
        onMarkedTextStateChanged(hasMarkedText())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextStateChanged(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextStateChanged(hasMarkedText())
    }

    override func copy(_ sender: Any?) {
        if copySelectedAttachments(to: .general) {
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard let payload = selectedAttachmentEditingPayload(),
              writeAttachments(payload.attachments, to: .general) else {
            super.cut(sender)
            return
        }
        deleteAttachmentSelection(in: payload.range, cleanupAttachmentFiles: false)
    }

    func openFilePicker() {
        onChooseFiles()
    }

    func recenterSingleLineTextContainer() {
        guard let layoutManager,
              let textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let lineFragmentCount = visualLineFragmentCount()

        let targetHeight = bounds.height > 0 ? bounds.height : TextBoxLayout.minimumTextHeight
        var targetVerticalInset: CGFloat
        if lineFragmentCount <= TextBoxLayout.minLines {
            let currentFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
            let singleLineHeight = max(
                TextBoxLayout.minimumTextHeight,
                lineHeight + TextBoxLayout.textInset.height * 2
            )
            let centeredHeight = min(targetHeight, singleLineHeight)
            targetVerticalInset = max(0, (centeredHeight - lineHeight) / 2)
        } else {
            targetVerticalInset = TextBoxLayout.multilineTextInset.height
        }
        if containsInlineTextAttachment() {
            targetVerticalInset = max(
                0,
                targetVerticalInset - TextBoxLayout.inlineAttachmentTextInsetCompensation
            )
        }

        let targetHorizontalInset = TextBoxLayout.textInset(forLineCount: lineFragmentCount).width
        let currentInset = textContainerInset
        guard abs(currentInset.height - targetVerticalInset) > 0.25
            || abs(currentInset.width - targetHorizontalInset) > 0.25 else { return }
        textContainerInset = NSSize(width: targetHorizontalInset, height: targetVerticalInset)
    }

    func visualLineFragmentCount() -> Int {
        guard let layoutManager,
              let textContainer else { return 1 }
        return Self.visualLineFragmentCount(
            textView: self,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }

    static func visualLineFragmentCount(
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> Int {
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var softLineCount = glyphRange.length == 0 ? 1 : 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            softLineCount += 1
        }
        let explicitLineCount = max(1, (textView.string as NSString).components(separatedBy: "\n").count)
        return max(softLineCount, explicitLineCount)
    }

    override func layout() {
        super.layout()
        recenterSingleLineTextContainer()
        guard !isReportingLayoutCompletion else { return }
        isReportingLayoutCompletion = true
        onLayoutCompleted(self)
        isReportingLayoutCompletion = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: insertionIndex(for: point), length: 0))
        return onInsertFileURLs(urls, self)
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return pasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { object -> URL? in
                if let url = object as? URL { return url }
                if let url = object as? NSURL { return url as URL }
                return nil
            }
            .filter(\.isFileURL) ?? []
    }

}
