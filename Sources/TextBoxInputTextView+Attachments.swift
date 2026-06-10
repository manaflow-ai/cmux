import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Inline Attachment Insertion & Hit Testing
extension TextBoxInputTextView {
    static let pendingAttachmentUploadPlaceholderCharacter = "\u{200B}"
    private static let pendingAttachmentUploadPlaceholderAttribute = NSAttributedString.Key(
        "cmux.textBoxPendingAttachmentUploadID"
    )
    func insertAttachments(_ attachments: [TextBoxAttachment]) {
        guard !attachments.isEmpty else { return }
        window?.makeFirstResponder(self)

        insertAttachments(attachments, replacementRange: selectedRange())
    }

    func insertPendingAttachmentUploadPlaceholder(id: UUID) {
        window?.makeFirstResponder(self)
        var attributes = currentTextAttributes()
        attributes[Self.pendingAttachmentUploadPlaceholderAttribute] = id.uuidString
        insertText(
            NSAttributedString(
                string: Self.pendingAttachmentUploadPlaceholderCharacter,
                attributes: attributes
            ),
            replacementRange: selectedRange()
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
    }

    @discardableResult
    func replacePendingAttachmentUploadPlaceholder(
        id: UUID,
        with attachments: [TextBoxAttachment]
    ) -> Bool {
        guard !attachments.isEmpty,
              let textStorage,
              let placeholderRange = pendingAttachmentUploadPlaceholderRange(id: id) else {
            return false
        }

        attachments.forEach(TextBoxDraftAttachmentStorage.prepareDurableCopy)
        let selectedRangeBeforeReplacement = selectedRange()
        let inserted = inlineAttachmentAttributedString(for: attachments, replacing: placeholderRange)
        textStorage.replaceCharacters(in: placeholderRange, with: inserted)
        setSelectedRange(
            adjustedSelectionRange(
                selectedRangeBeforeReplacement,
                replacing: placeholderRange,
                insertedLength: inserted.length
            )
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        return true
    }

    @discardableResult
    func removePendingAttachmentUploadPlaceholder(id: UUID) -> Bool {
        guard let textStorage,
              let placeholderRange = pendingAttachmentUploadPlaceholderRange(id: id) else {
            return false
        }

        let selectedRangeBeforeRemoval = selectedRange()
        textStorage.replaceCharacters(in: placeholderRange, with: NSAttributedString(string: ""))
        setSelectedRange(
            adjustedSelectionRange(
                selectedRangeBeforeRemoval,
                replacing: placeholderRange,
                insertedLength: 0
            )
        )
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        return true
    }

    func hasPendingAttachmentUploadPlaceholder() -> Bool {
        pendingAttachmentUploadPlaceholderRange(id: nil) != nil
    }

    private func insertAttachments(
        _ attachments: [TextBoxAttachment],
        replacementRange: NSRange
    ) {
        guard !attachments.isEmpty else { return }
        attachments.forEach(TextBoxDraftAttachmentStorage.prepareDurableCopy)
        let inserted = NSMutableAttributedString()
        inserted.append(inlineAttachmentAttributedString(for: attachments, replacing: replacementRange))
        insertText(inserted, replacementRange: replacementRange)
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
    }

    func refreshInlineAttachmentCells(font: NSFont, foregroundColor: NSColor) {
        let attributed = attributedString()
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            attachment.refreshCell(
                font: font,
                foregroundColor: foregroundColor,
                isFocused: isAttachmentFocused(at: range.location)
            )
        }
        normalizeTextBaselineOffsets()
        typingAttributes = currentTextAttributes(font: font, foregroundColor: foregroundColor)
        recenterSingleLineTextContainer()
    }

    func refreshInlineAttachmentFocus() {
        if !isFocusedAttachmentSelectionValid() {
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
        }
        refreshInlineAttachmentCells(
            font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            foregroundColor: textColor ?? .labelColor
        )
    }

#if DEBUG
    func installDebugInlineFixture(
        _ attachment: TextBoxAttachment?,
        beforeText: String,
        afterText: String
    ) {
        let textAttributes = currentTextAttributes()
        let attributed = NSMutableAttributedString(string: beforeText, attributes: textAttributes)
        if let attachment {
            attributed.append(inlineAttachmentAttributedString(for: attachment))
        }
        attributed.append(NSAttributedString(string: afterText, attributes: textAttributes))

        textStorage?.setAttributedString(attributed)
        normalizeTextBaselineOffsets()
        typingAttributes = currentTextAttributes()
        setSelectedRange(NSRange(location: attributed.length, length: 0))
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        recenterSingleLineTextContainer()
        scrollRangeToVisible(NSRange(location: attributed.length, length: 0))
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
        window?.displayIfNeeded()
        didChangeText()
    }

    @discardableResult
    func debugInteract(action: String) -> [String: Any] {
        window?.makeFirstResponder(self)

        switch action {
        case "focus":
            break
        case "submit":
            submitIfAllowed()
        case "select_first_attachment":
            if let characterIndex = firstInlineAttachmentCharacterIndex() {
                selectAttachment(at: characterIndex)
            }
        case "close_first_attachment":
            if let characterIndex = firstInlineAttachmentCharacterIndex() {
                deleteAttachment(at: characterIndex)
            }
        case "preview_first_attachment":
            if let characterIndex = firstInlineAttachmentCharacterIndex(),
               let attachment = attachment(at: characterIndex) {
                showAttachmentPreview(attachment, characterIndex: characterIndex)
            }
        case "open_preview":
            if let focused = focusedAttachment() {
                TextBoxAttachmentPreviewOpening.openInPreview(focused.attachment)
            }
        case "space":
            if let focused = focusedAttachment() {
                toggleAttachmentPreview(focused.attachment, characterIndex: focused.characterIndex)
            }
        case "left":
            moveInsertionPointLeft()
        case "right":
            moveInsertionPointRight()
        case "escape":
            if isAttachmentPreviewShown {
                dismissAttachmentPreview()
            } else {
                clearAttachmentFocus(dismissPreview: true)
                refreshInlineAttachmentFocus()
            }
        default:
            break
        }

        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
        window?.displayIfNeeded()
        return debugInteractionState()
    }

    func debugInteractionState() -> [String: Any] {
        let selection = selectedRange()
        let mentionQuery = mentionCompletionController.activeQuery
        return [
            "selected_location": selection.location,
            "selected_length": selection.length,
            "focused_attachment_index": focusedAttachmentCharacterIndex ?? -1,
            "preview_shown": isAttachmentPreviewShown,
            "attachment_count": inlineAttachments().count,
            "plain_text": plainText(),
            "mention_active": mentionCompletionController.isActive,
            "mention_query": mentionQuery?.query ?? "",
            "mention_trigger": mentionQuery.map { String($0.trigger) } ?? "",
            "mention_loading": mentionCompletionController.isLoadingSuggestions,
            "mention_should_show": mentionCompletionController.debugShouldShowPopover,
            "mention_current": mentionCompletionController.debugHasCurrentSuggestions,
            "mention_titles": mentionCompletionController.debugSuggestionTitles
        ]
    }

    private func firstInlineAttachmentCharacterIndex() -> Int? {
        var result: Int?
        attributedString().enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString().length),
            options: []
        ) { value, range, stop in
            guard value is TextBoxInlineTextAttachment else { return }
            result = range.location
            stop.pointee = true
        }
        return result
    }
#endif

    func pendingAttachmentUploadValidationToken() -> UInt64 {
        attachmentUploadInvalidationGeneration
    }

    func canAcceptPendingAttachmentUpload(validationToken: UInt64) -> Bool {
        attachmentUploadInvalidationGeneration == validationToken && window != nil
    }

    func invalidatePendingAttachmentUploads() {
        attachmentUploadInvalidationGeneration &+= 1
    }

    struct InlineAttachmentHit {
        let attachment: TextBoxAttachment
        let characterIndex: Int
        let point: NSPoint
        let closeRect: NSRect
    }

    static let attachmentReplacementCharacter = "\u{FFFC}"

    func currentTextAttributes(
        font explicitFont: NSFont? = nil,
        foregroundColor explicitForegroundColor: NSColor? = nil
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: explicitFont ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: explicitForegroundColor ?? textColor ?? .labelColor,
            .baselineOffset: textBaselineOffsetForCurrentContent()
        ]
    }

    func inlineAttachmentAttributedString(for attachment: TextBoxAttachment) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attachment: TextBoxInlineTextAttachment(
                attachment: attachment,
                font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                foregroundColor: textColor ?? .labelColor
            )
        )
        attributed.addAttribute(
            .baselineOffset,
            value: TextBoxLayout.textBaselineOffset,
            range: NSRange(location: 0, length: attributed.length)
        )
        return attributed
    }

    private func inlineAttachmentAttributedString(for attachments: [TextBoxAttachment]) -> NSAttributedString {
        let inserted = NSMutableAttributedString()
        for (index, attachment) in attachments.enumerated() {
            if index > 0 {
                inserted.append(NSAttributedString(string: " ", attributes: currentTextAttributes()))
            }
            inserted.append(inlineAttachmentAttributedString(for: attachment))
        }
        return inserted
    }

    private func inlineAttachmentAttributedString(
        for attachments: [TextBoxAttachment],
        replacing range: NSRange
    ) -> NSAttributedString {
        let inserted = NSMutableAttributedString()
        if shouldInsertAttachmentBoundarySpaceBefore(replacementRange: range) {
            inserted.append(NSAttributedString(string: " ", attributes: currentTextAttributes()))
        }
        inserted.append(inlineAttachmentAttributedString(for: attachments))
        if shouldInsertAttachmentBoundarySpaceAfter(
            replacementRange: range,
            attachments: attachments
        ) {
            inserted.append(NSAttributedString(string: " ", attributes: currentTextAttributes()))
        }
        return inserted
    }

    private func shouldInsertAttachmentBoundarySpaceBefore(replacementRange: NSRange) -> Bool {
        guard replacementRange.location > 0,
              replacementRange.location <= attributedString().length else {
            return false
        }
        return !isAttachmentBoundarySeparator(at: replacementRange.location - 1)
    }

    private func shouldInsertAttachmentBoundarySpaceAfter(
        replacementRange: NSRange,
        attachments: [TextBoxAttachment]
    ) -> Bool {
        guard attachments.contains(where: \.isImage) else {
            return false
        }
        let afterLocation = NSMaxRange(replacementRange)
        guard afterLocation >= 0,
              afterLocation < attributedString().length else {
            return true
        }
        return !isAttachmentBoundarySeparator(at: afterLocation)
    }

    private func isAttachmentBoundarySeparator(at location: Int) -> Bool {
        guard location >= 0,
              location < attributedString().length else {
            return true
        }
        let character = (attributedString().string as NSString).substring(with: NSRange(location: location, length: 1))
        return character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func pendingAttachmentUploadPlaceholderRanges(
        in attributed: NSAttributedString,
        id: UUID?
    ) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return [] }

        let idString = id?.uuidString
        var result: [NSRange] = []
        attributed.enumerateAttribute(
            Self.pendingAttachmentUploadPlaceholderAttribute,
            in: fullRange,
            options: []
        ) { value, range, stop in
            guard let value = value as? String,
                  idString == nil || value == idString else {
                return
            }
            result.append(range)
            if idString != nil {
                stop.pointee = true
            }
        }
        return result
    }

    static func removePendingAttachmentUploadPlaceholders(from attributed: NSMutableAttributedString) {
        for range in pendingAttachmentUploadPlaceholderRanges(in: attributed, id: nil).reversed() {
            attributed.replaceCharacters(in: range, with: NSAttributedString(string: ""))
        }
    }

    private func pendingAttachmentUploadPlaceholderRange(id: UUID?) -> NSRange? {
        Self.pendingAttachmentUploadPlaceholderRanges(in: attributedString(), id: id).first
    }

    func attachmentRect(forCharacterIndex characterIndex: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer,
              characterIndex >= 0,
              characterIndex < attributedString().length,
              attributedString().attribute(
                .attachment,
                at: characterIndex,
                effectiveRange: nil
              ) is TextBoxInlineTextAttachment else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        var attachmentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        attachmentRect.origin.x += textContainerOrigin.x
        attachmentRect.origin.y += textContainerOrigin.y
        return attachmentRect
    }

    func inlineAttachmentHit(for event: NSEvent) -> InlineAttachmentHit? {
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager,
              let textContainer,
              attributedString().length > 0 else {
            return nil
        }

        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex >= 0,
              characterIndex < attributedString().length,
              let inlineAttachment = attributedString().attribute(
                .attachment,
                at: characterIndex,
                effectiveRange: nil
              ) as? TextBoxInlineTextAttachment else {
            return nil
        }

        guard let attachmentRect = attachmentRect(forCharacterIndex: characterIndex) else {
            return nil
        }
        guard attachmentRect.insetBy(dx: -2, dy: -4).contains(point) else {
            return nil
        }

        return InlineAttachmentHit(
            attachment: inlineAttachment.textBoxAttachment,
            characterIndex: characterIndex,
            point: point,
            closeRect: NSRect(
                x: attachmentRect.maxX - TextBoxLayout.inlineAttachmentTrailingControlWidth - 2,
                y: attachmentRect.minY,
                width: TextBoxLayout.inlineAttachmentTrailingControlWidth + 2,
                height: attachmentRect.height
            )
        )
    }

    func insertionIndex(for point: NSPoint) -> Int {
        guard let layoutManager,
              let textContainer,
              attributedString().length > 0 else {
            return 0
        }

        var fraction: CGFloat = 0
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return min(attributedString().length, characterIndex + (fraction > 0.5 ? 1 : 0))
    }

}
