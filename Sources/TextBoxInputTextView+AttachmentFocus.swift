import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Attachment Focus, Selection & Preview
extension TextBoxInputTextView {
    var isAttachmentPreviewShown: Bool {
        attachmentPreviewPopover?.isShown == true
    }

    func moveInsertionPointLeft() {
        if moveFocusedAttachmentSelection(toTrailingEdge: false) {
            return
        }

        let range = selectedRange()
        if range.length > 0 {
            setSelectedRange(NSRange(location: range.location, length: 0))
            clearAttachmentFocus(dismissPreview: true)
            refreshInlineAttachmentFocus()
            return
        }
        let nextLocation = composedCharacterLocationBefore(range.location)
        guard nextLocation < range.location else { return }
        setSelectedRange(NSRange(location: nextLocation, length: 0))
        clearAttachmentFocus(dismissPreview: true)
        refreshInlineAttachmentFocus()
    }

    func deleteAttachment(at characterIndex: Int) {
        deleteAttachmentSelection(in: NSRange(location: characterIndex, length: 1))
    }

    enum KeyboardDeleteDirection {
        case backward
        case forward
    }

    func deleteAttachmentForKeyboardCommand(direction: KeyboardDeleteDirection) -> Bool {
        let range = selectedRange()
        if range.length > 0 {
            guard !inlineAttachments(in: range).isEmpty else {
                return false
            }
            deleteAttachmentSelection(in: range)
            return true
        }

        let attachmentLocation: Int?
        switch direction {
        case .backward:
            attachmentLocation = range.location > 0 ? range.location - 1 : nil
        case .forward:
            attachmentLocation = range.location < attributedString().length ? range.location : nil
        }

        guard let attachmentLocation,
              attachment(at: attachmentLocation) != nil else {
            return false
        }
        deleteAttachmentSelection(in: NSRange(location: attachmentLocation, length: 1))
        return true
    }

    func moveInsertionPointRight() {
        if moveFocusedAttachmentSelection(toTrailingEdge: true) {
            return
        }

        let range = selectedRange()
        if range.length > 0 {
            setSelectedRange(NSRange(location: range.location + range.length, length: 0))
            clearAttachmentFocus(dismissPreview: true)
            refreshInlineAttachmentFocus()
            return
        }
        let nextLocation = composedCharacterLocationAfter(range.location)
        guard nextLocation > range.location else { return }
        setSelectedRange(NSRange(location: nextLocation, length: 0))
        clearAttachmentFocus(dismissPreview: true)
        refreshInlineAttachmentFocus()
    }

    private func composedCharacterLocationBefore(_ location: Int) -> Int {
        let nsText = string as NSString
        let clampedLocation = min(max(location, 0), nsText.length)
        guard clampedLocation > 0 else { return clampedLocation }
        return nsText.rangeOfComposedCharacterSequence(at: clampedLocation - 1).location
    }

    private func composedCharacterLocationAfter(_ location: Int) -> Int {
        let nsText = string as NSString
        let clampedLocation = min(max(location, 0), nsText.length)
        guard clampedLocation < nsText.length else { return clampedLocation }
        return NSMaxRange(nsText.rangeOfComposedCharacterSequence(at: clampedLocation))
    }

    func selectAttachment(at characterIndex: Int) {
        guard attachment(at: characterIndex) != nil else {
            clearAttachmentFocus(dismissPreview: true)
            return
        }
        attachmentPreviewCharacterIndex = characterIndex
        focusedAttachmentCharacterIndex = characterIndex
        setSelectedRange(NSRange(location: characterIndex, length: 1))
        scrollRangeToVisible(NSRange(location: characterIndex, length: 1))
        installAttachmentKeyDownMonitorIfNeeded()
        refreshInlineAttachmentFocus()
    }

    func focusedAttachment() -> (attachment: TextBoxAttachment, characterIndex: Int)? {
        let range = selectedRange()
        if let focusedAttachmentCharacterIndex,
           range.location == focusedAttachmentCharacterIndex,
           range.length == 1,
           let attachment = attachment(at: focusedAttachmentCharacterIndex) {
            return (attachment, focusedAttachmentCharacterIndex)
        }
        if focusedAttachmentCharacterIndex != nil {
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
        }

        if range.length == 1,
           let attachment = attachment(at: range.location) {
            focusedAttachmentCharacterIndex = range.location
            installAttachmentKeyDownMonitorIfNeeded()
            return (attachment, range.location)
        }

        return nil
    }

    func isAttachmentFocused(at characterIndex: Int) -> Bool {
        focusedAttachmentCharacterIndex == characterIndex
    }

    func isFocusedAttachmentSelectionValid() -> Bool {
        guard let focusedAttachmentCharacterIndex else { return false }
        let range = selectedRange()
        guard range.location == focusedAttachmentCharacterIndex,
              range.length == 1 else {
            return false
        }
        return attachment(at: focusedAttachmentCharacterIndex) != nil
    }

    func attachment(at characterIndex: Int) -> TextBoxAttachment? {
        guard characterIndex >= 0,
              characterIndex < attributedString().length,
              let inlineAttachment = attributedString().attribute(
                .attachment,
                at: characterIndex,
                effectiveRange: nil
              ) as? TextBoxInlineTextAttachment else {
            return nil
        }
        return inlineAttachment.textBoxAttachment
    }

    func moveFocusedAttachmentSelection(toTrailingEdge: Bool) -> Bool {
        guard let focused = focusedAttachment() else { return false }
        let insertionLocation = focused.characterIndex + (toTrailingEdge ? 1 : 0)
        setSelectedRange(NSRange(location: insertionLocation, length: 0))
        clearAttachmentFocus(dismissPreview: true)
        refreshInlineAttachmentFocus()
        return true
    }

    func toggleAttachmentPreview(
        _ attachment: TextBoxAttachment,
        characterIndex: Int
    ) {
        if isAttachmentPreviewShown,
           attachmentPreviewCharacterIndex == characterIndex {
            dismissAttachmentPreview()
            return
        }
        showAttachmentPreview(attachment, characterIndex: characterIndex)
    }

    func handleFocusedAttachmentKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let focused = focusedAttachment() else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_Space:
            toggleAttachmentPreview(focused.attachment, characterIndex: focused.characterIndex)
            return true
        case kVK_LeftArrow:
            _ = moveFocusedAttachmentSelection(toTrailingEdge: false)
            return true
        case kVK_RightArrow:
            _ = moveFocusedAttachmentSelection(toTrailingEdge: true)
            return true
        case kVK_Escape:
            if isAttachmentPreviewShown {
                dismissAttachmentPreview()
                return true
            }
            clearAttachmentFocus(dismissPreview: true)
            refreshInlineAttachmentFocus()
            return true
        default:
            clearAttachmentFocus(dismissPreview: isAttachmentPreviewShown)
            refreshInlineAttachmentFocus()
            return false
        }
    }

    func showAttachmentPreview(
        _ attachment: TextBoxAttachment,
        characterIndex: Int
    ) {
        guard attachment.localURL != nil,
              let attachmentRect = attachmentRect(forCharacterIndex: characterIndex) else {
            NSSound.beep()
            return
        }

        dismissAttachmentPreview()
        selectAttachment(at: characterIndex)
        preserveAttachmentFocusOnNextResign = true

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = TextBoxAttachmentPreviewController(attachment: attachment)
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        attachmentPreviewPopover = popover
        attachmentPreviewCharacterIndex = characterIndex
        popover.show(relativeTo: attachmentRect, of: self, preferredEdge: .maxY)
        window?.makeFirstResponder(self)
        installAttachmentKeyDownMonitorIfNeeded()
    }

    func dismissAttachmentPreview() {
        attachmentPreviewPopover?.performClose(nil)
        attachmentPreviewPopover = nil
        attachmentPreviewCharacterIndex = nil
    }

    func clearAttachmentFocus(dismissPreview shouldDismissPreview: Bool) {
        if shouldDismissPreview {
            dismissAttachmentPreview()
        }
        focusedAttachmentCharacterIndex = nil
        removeAttachmentKeyDownMonitor()
    }

    func copySelectedAttachments(to pasteboard: NSPasteboard) -> Bool {
        guard let payload = selectedAttachmentEditingPayload() else { return false }
        return writeAttachments(payload.attachments, to: pasteboard)
    }

    func selectedAttachmentEditingPayload() -> (attachments: [TextBoxAttachment], range: NSRange)? {
        if let focused = focusedAttachment() {
            return ([focused.attachment], NSRange(location: focused.characterIndex, length: 1))
        }

        let range = selectedRange()
        guard isValidSelectedRange(range), range.length > 0 else { return nil }

        let attributed = attributedString()
        let raw = attributed.string as NSString
        var attachments: [TextBoxAttachment] = []
        var nonAttachmentContent = ""
        attributed.enumerateAttribute(.attachment, in: range, options: []) { value, subrange, _ in
            if let inlineAttachment = value as? TextBoxInlineTextAttachment {
                attachments.append(inlineAttachment.textBoxAttachment)
            } else {
                nonAttachmentContent += raw.substring(with: subrange)
            }
        }

        guard !attachments.isEmpty,
              nonAttachmentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (attachments, range)
    }

    func isValidSelectedRange(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0 else {
            return false
        }
        return NSMaxRange(range) <= attributedString().length
    }

    func writeAttachments(
        _ attachments: [TextBoxAttachment],
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard !attachments.isEmpty else { return false }

        let fileURLs = attachments.compactMap(\.localURL)
        let submissionText = attachments
            .map(\.submissionText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var types: [NSPasteboard.PasteboardType] = [.string]
        if !fileURLs.isEmpty {
            types.append(.fileURL)
            types.append(PasteboardFileURLReader.legacyFilenamesPboardType)
        }

        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)

        var wroteContent = false
        if !fileURLs.isEmpty {
            if let firstURL = fileURLs.first {
                wroteContent = pasteboard.setString(firstURL.absoluteString, forType: .fileURL) || wroteContent
            }
            wroteContent = pasteboard.setPropertyList(
                fileURLs.map(\.path),
                forType: PasteboardFileURLReader.legacyFilenamesPboardType
            ) || wroteContent
        }

        if !submissionText.isEmpty {
            wroteContent = pasteboard.setString(submissionText, forType: .string) || wroteContent
        } else if let firstURL = fileURLs.first {
            wroteContent = pasteboard.setString(firstURL.path, forType: .string) || wroteContent
        }
        return wroteContent
    }

    func deleteAttachmentSelection(
        in range: NSRange,
        cleanupAttachmentFiles: Bool = true
    ) {
        guard isValidSelectedRange(range),
              range.length > 0 else {
            return
        }

        let removedAttachments = inlineAttachments(in: range)
        suppressAutomaticAttachmentFileCleanup = true
        defer { suppressAutomaticAttachmentFileCleanup = false }
        insertText("", replacementRange: range)
        if cleanupAttachmentFiles {
            cleanupRemovedAttachmentFiles(removedAttachments)
        } else {
            removePendingAttachmentCleanup(for: removedAttachments)
        }
        clearAttachmentFocus(dismissPreview: true)
        setSelectedRange(NSRange(location: min(range.location, (string as NSString).length), length: 0))
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
    }

    func inlineAttachments(in range: NSRange) -> [TextBoxAttachment] {
        guard isValidSelectedRange(range),
              range.length > 0 else {
            return []
        }
        var result: [TextBoxAttachment] = []
        attributedString().enumerateAttribute(.attachment, in: range, options: []) { value, _, _ in
            guard let attachment = value as? TextBoxInlineTextAttachment else { return }
            result.append(attachment.textBoxAttachment)
        }
        return result
    }

    func installAttachmentKeyDownMonitorIfNeeded() {
        guard attachmentKeyDownMonitor == nil else { return }
        attachmentKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.shouldHandleAttachmentMonitorEvent(event) else { return event }
            return self.handleFocusedAttachmentKeyEvent(event) ? nil : event
        }
    }

    func removeAttachmentKeyDownMonitor() {
        if let attachmentKeyDownMonitor {
            NSEvent.removeMonitor(attachmentKeyDownMonitor)
            self.attachmentKeyDownMonitor = nil
        }
    }

    private func shouldHandleAttachmentMonitorEvent(_ event: NSEvent) -> Bool {
        guard focusedAttachmentCharacterIndex != nil else { return false }
        if event.window === window {
            return true
        }
        if event.window === attachmentPreviewPopover?.contentViewController?.view.window {
            return true
        }
        return false
    }

}
