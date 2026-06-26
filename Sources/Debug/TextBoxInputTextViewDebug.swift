import AppKit

#if DEBUG
extension TextBoxInputTextView {
    func installInlineControlFixture(
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

        setControlAttributedText(attributed)
    }

    @discardableResult
    func performControlInteraction(action: String) -> [String: Any] {
        window?.makeFirstResponder(self)

        switch action {
        case "focus":
            break
        case "submit":
            submitIfAllowed()
        case let setTextAction where setTextAction.hasPrefix("set_text:"):
            setControlAttributedText(NSAttributedString(
                string: String(setTextAction.dropFirst("set_text:".count)),
                attributes: currentTextAttributes()
            ))
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
        return controlInteractionState()
    }

    private func setControlAttributedText(_ attributed: NSAttributedString) {
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

    func controlInteractionState() -> [String: Any] {
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
            guard value != nil,
                  attachment(at: range.location) != nil else { return }
            result = range.location
            stop.pointee = true
        }
        return result
    }
}
#endif
