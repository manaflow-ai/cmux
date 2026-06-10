import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Content, Drafts & Normalization
extension TextBoxInputTextView {
    func clearContent(cleanupAttachmentFiles: Bool = true) {
        if cleanupAttachmentFiles {
            cleanupDisposableAttachmentFiles(
                inlineAttachments(),
                preservingActiveInlineAttachments: false
            )
        }
        invalidatePendingAttachmentUploads()
        dismissMentionCompletions()
        clearAttachmentFocus(dismissPreview: true)
        textStorage?.setAttributedString(NSAttributedString(string: ""))
        recenterSingleLineTextContainer()
        didChangeText()
    }

    func prepareForSubmit() {
        flushAutomaticAttachmentFileCleanup()
        discardUndoHistoryAndCleanupPendingAttachmentFiles()
    }

    /// Installs preserved attributed content into the text view.
    ///
    /// Pass `false` for `notifyingTextChange` only from representable construction paths where
    /// the owning panel already has the current draft state. That restores AppKit storage without
    /// running delegate or binding side effects during SwiftUI lifecycle work.
    func installPreservedContent(_ content: NSAttributedString, notifyingTextChange: Bool = true) {
        installAttributedContent(content, notifyingTextChange: notifyingTextChange)
    }

    /// Installs a saved session draft into the text view.
    ///
    /// Pass `false` for `notifyingTextChange` only from representable construction paths where
    /// the owning panel already has the current draft state. That restores AppKit storage without
    /// running delegate or binding side effects during SwiftUI lifecycle work.
    func installSessionDraft(_ draft: SessionTextBoxInputDraftSnapshot, notifyingTextChange: Bool = true) {
        installAttributedContent(
            attributedContent(from: draft),
            notifyingTextChange: notifyingTextChange
        )
    }

    private func installAttributedContent(_ content: NSAttributedString, notifyingTextChange: Bool) {
        invalidatePendingAttachmentUploads()
        dismissMentionCompletions()
        clearAttachmentFocus(dismissPreview: true)
        textStorage?.setAttributedString(content)
        refreshInlineAttachmentCells(
            font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
        typingAttributes = currentTextAttributes()
        setSelectedRange(NSRange(location: attributedString().length, length: 0))
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        recenterSingleLineTextContainer()
        if notifyingTextChange {
            didChangeText()
        } else {
            flushAutomaticAttachmentFileCleanup()
        }
    }

    func attributedContentForPreservation() -> NSAttributedString {
        let preserved = NSMutableAttributedString(attributedString: attributedString())
        Self.removePendingAttachmentUploadPlaceholders(from: preserved)
        return preserved
    }

    func sessionDraftSnapshot(isActive: Bool) -> SessionTextBoxInputDraftSnapshot? {
        Self.sessionDraftSnapshot(from: attributedContentForPreservation(), isActive: isActive)
    }

    static func sessionDraftSnapshot(
        from attributed: NSAttributedString,
        isActive: Bool
    ) -> SessionTextBoxInputDraftSnapshot? {
        sessionDraftSnapshot(
            parts: TextBoxSubmissionFormatter.parts(from: attributed),
            isActive: isActive
        )
    }

    static func sessionDraftSnapshot(
        text: String,
        attachments: [TextBoxAttachment],
        isActive: Bool
    ) -> SessionTextBoxInputDraftSnapshot? {
        var parts: [TextBoxSubmissionPart] = []
        if !text.isEmpty {
            parts.append(.text(text))
        }
        parts.append(contentsOf: attachments.map { .attachment($0) })
        return sessionDraftSnapshot(parts: parts, isActive: isActive)
    }

    static func plainText(from draft: SessionTextBoxInputDraftSnapshot) -> String {
        draft.parts.compactMap { part -> String? in
            guard part.kind == .text else { return nil }
            return part.text
        }.joined()
    }

    static func attachments(from draft: SessionTextBoxInputDraftSnapshot) -> [TextBoxAttachment] {
        draft.parts.compactMap { part -> TextBoxAttachment? in
            guard part.kind == .attachment,
                  let attachment = part.attachment else { return nil }
            return attachment.textBoxAttachment()
        }
    }

    private static func sessionDraftSnapshot(
        parts: [TextBoxSubmissionPart],
        isActive: Bool
    ) -> SessionTextBoxInputDraftSnapshot? {
        let draftParts = parts.compactMap { part -> SessionTextBoxInputDraftPart? in
            switch part {
            case .text(let text):
                guard !text.isEmpty else { return nil }
                return .text(text)
            case .attachment(let attachment):
                return .attachment(SessionTextBoxInputAttachmentSnapshot(attachment))
            }
        }
        let hasMeaningfulContent = draftParts.contains { part in
            switch part.kind {
            case .text:
                return part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case .attachment:
                return part.attachment != nil
            }
        }
        guard hasMeaningfulContent else { return nil }
        return SessionTextBoxInputDraftSnapshot(isActive: isActive, parts: draftParts)
    }

    private func attributedContent(from draft: SessionTextBoxInputDraftSnapshot) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        for part in draft.parts {
            switch part.kind {
            case .text:
                guard let text = part.text,
                      !text.isEmpty else { continue }
                attributed.append(NSAttributedString(string: text, attributes: currentTextAttributes()))
            case .attachment:
                guard let attachment = part.attachment?.textBoxAttachment() else { continue }
                attributed.append(inlineAttachmentAttributedString(for: attachment))
            }
        }
        return attributed
    }

    func plainText() -> String {
        stringByStrippingNonTextMarkers(from: attributedString().string)
    }

    func inlineAttachments() -> [TextBoxAttachment] {
        var result: [TextBoxAttachment] = []
        attributedString().enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString().length),
            options: []
        ) { value, _, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            result.append(attachment.textBoxAttachment)
        }
        return result
    }

    func submissionText() -> String {
        TextBoxSubmissionFormatter.formattedText(from: attributedString())
    }

    func submissionParts() -> [TextBoxSubmissionPart] {
        TextBoxSubmissionFormatter.parts(from: attributedString())
    }

    func hasSubmittableContent() -> Bool {
        TextBoxSubmissionFormatter.hasSubmittableContent(submissionParts())
    }

    func adjustedSelectionRange(
        _ selectedRange: NSRange,
        replacing replacedRange: NSRange,
        insertedLength: Int
    ) -> NSRange {
        guard isValidSelectedRange(selectedRange) else {
            return NSRange(location: NSMaxRange(replacedRange) + insertedLength, length: 0)
        }

        let delta = insertedLength - replacedRange.length
        if selectedRange.location > replacedRange.location {
            return NSRange(
                location: max(0, selectedRange.location + delta),
                length: selectedRange.length
            )
        }
        if NSIntersectionRange(selectedRange, replacedRange).length > 0 {
            return NSRange(location: replacedRange.location + insertedLength, length: 0)
        }
        return selectedRange
    }

    static func stringByStrippingNonTextMarkers(from text: String) -> String {
        text
            .replacingOccurrences(of: String(Self.attachmentReplacementCharacter), with: "")
            .replacingOccurrences(of: Self.pendingAttachmentUploadPlaceholderCharacter, with: "")
    }

    private func stringByStrippingNonTextMarkers(from text: String) -> String {
        Self.stringByStrippingNonTextMarkers(from: text)
    }

    func normalizeTextBaselineOffsets() {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else {
            typingAttributes = currentTextAttributes()
            return
        }

        let textOffset = TextBoxLayout.textBaselineOffset

        var updates: [(NSRange, CGFloat)] = []
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            let targetOffset = value == nil ? textOffset : TextBoxLayout.textBaselineOffset
            let currentOffset = Self.baselineOffsetValue(
                textStorage.attribute(.baselineOffset, at: range.location, effectiveRange: nil)
            )
            guard abs(currentOffset - targetOffset) > 0.01 else { return }
            updates.append((range, targetOffset))
        }
        guard !updates.isEmpty else {
            typingAttributes = currentTextAttributes()
            return
        }

        textStorage.beginEditing()
        for (range, targetOffset) in updates {
            textStorage.addAttribute(.baselineOffset, value: targetOffset, range: range)
        }
        textStorage.endEditing()
        typingAttributes = currentTextAttributes()
    }

    func textBaselineOffsetForCurrentContent() -> CGFloat {
        TextBoxLayout.textBaselineOffset
    }

    func containsInlineTextAttachment() -> Bool {
        guard let textStorage else { return false }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var foundAttachment = false
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, stop in
            guard value != nil else { return }
            foundAttachment = true
            stop.pointee = true
        }
        return foundAttachment
    }

    private static func baselineOffsetValue(_ value: Any?) -> CGFloat {
        if let value = value as? CGFloat {
            return value
        }
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        return 0
    }

}
