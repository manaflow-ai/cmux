import AppKit
import SwiftUI

@MainActor
extension OmnibarTextFieldRepresentable.Coordinator {
    func queueSelectAllRequest(_ requestId: UInt64) {
        guard requestId != 0, appliedSelectAllRequestId != requestId else { return }
        pendingSelectAllRequestId = requestId
    }

    @discardableResult
    func applyPendingSelectAllIfPossible(
        field: OmnibarNativeTextField
    ) -> Bool {
        guard let requestId = pendingSelectAllRequestId,
              requestId != 0,
              appliedSelectAllRequestId != requestId else {
            return false
        }

        guard let editor = field.currentEditor() as? NSTextView,
              !editor.hasMarkedText() else {
            return false
        }
        let length = editor.string.utf16.count
        isProgrammaticMutation = true
        editor.setSelectedRange(NSRange(location: 0, length: length))
        isProgrammaticMutation = false
        appliedSelectAllRequestId = requestId
        pendingSelectAllRequestId = nil
        publishSelectionState()
        return true
    }

    func publishSelectionState() {
        guard let field = parentField else { return }
        if let editor = field.currentEditor() as? NSTextView {
            let range = editor.selectedRange()
            let hasMarkedText = editor.hasMarkedText()
            guard !NSEqualRanges(range, lastPublishedSelection) || hasMarkedText != lastPublishedHasMarkedText else {
                return
            }
            lastPublishedSelection = range
            lastPublishedHasMarkedText = hasMarkedText
            parent.onSelectionChanged(range, hasMarkedText)
        } else {
            let location = field.stringValue.utf16.count
            let range = NSRange(location: location, length: 0)
            guard !NSEqualRanges(range, lastPublishedSelection) || lastPublishedHasMarkedText else { return }
            lastPublishedSelection = range
            lastPublishedHasMarkedText = false
            parent.onSelectionChanged(range, false)
        }
    }

    /// Captures the field-editor text synchronously at submit time. Both
    /// Return interception paths (`doCommandBy` and `handleKeyEvent`) go
    /// through here so the submit decision always starts from what the
    /// field actually shows, not the possibly lagging published state.
    func liveFieldSnapshot(preferredEditor: NSTextView?) -> OmnibarLiveFieldSnapshot? {
        let editor = preferredEditor ?? (parentField?.currentEditor() as? NSTextView)
        if let editor {
            return OmnibarLiveFieldSnapshot(
                text: editor.string,
                selectionRange: editor.selectedRange(),
                hasMarkedText: editor.hasMarkedText()
            )
        }
        guard let field = parentField else { return nil }
        return OmnibarLiveFieldSnapshot(
            text: field.stringValue,
            selectionRange: nil,
            hasMarkedText: false
        )
    }

    func inlineCompletionSelectionIsActive(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        suffixSelectionMatchesInline(editor, inline: inline) || selectionIsTypedPrefixBoundary(editor, inline: inline)
    }

    func suffixSelectionMatchesInline(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        guard let editor, let inline else { return false }
        let selected = editor.selectedRange()
        return NSEqualRanges(selected, inline.suffixRange)
    }

    func selectionIsTypedPrefixBoundary(_ editor: NSTextView?, inline: OmnibarInlineCompletion?) -> Bool {
        guard let editor, let inline else { return false }
        let selected = editor.selectedRange()
        let typedCount = inline.typedText.utf16.count
        return selected.location == typedCount && selected.length == 0
    }

    func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.handleKeyEvent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
#endif
        // #6250: AppKit invokes `performKeyEquivalent` across the entire
        // window view hierarchy, so this coordinator runs even while web
        // content (the WKWebView) — not the omnibar — owns first responder.
        // In that state the omnibar field has no field editor, so `editor`
        // is nil. Treating Return/Escape/arrows (and Ctrl+N/P, Shift+Delete)
        // as omnibar input there makes an *unfocused* omnibar submit and
        // hard-navigate the pane on a physical Enter that belongs to the
        // page — a spurious reload that aborts in-flight `fetch`/XHR in SPAs.
        // Only act on these keys while the field is actually being edited.
        // This mirrors the `currentEditor()`-gated `insertNewline:` path in
        // `control(_:textView:doCommandBy:)`, which only runs for the live
        // field editor.
        guard editor != nil else { return false }
        guard editor?.hasMarkedText() != true else { return false }
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option, .function])
        // When a non-Latin input source is active (Korean, Chinese, Japanese),
        // charactersIgnoringModifiers returns non-ASCII characters. Normalize
        // via KeyboardLayout so Ctrl+N/P navigation works across input sources.
        let lowered = KeyboardLayout.normalizedCharacters(for: event)

        // Ctrl+N and Ctrl+P should repeat while held.
        if let delta = browserOmnibarSelectionDeltaForControlNavigation(
            hasFocusedAddressBar: true,
            flags: event.modifierFlags,
            chars: lowered
        ) {
            parent.onMoveSelection(delta)
#if DEBUG
            handled = true
#endif
            return true
        }

        // Shift+Delete removes the selected history suggestion when possible.
        if modifiers.contains(.shift), (keyCode == 51 || keyCode == 117) {
            parent.onDeleteSelectedSuggestion()
#if DEBUG
            handled = true
#endif
            return true
        }

        switch keyCode {
        case 36, 76: // Return / keypad Enter
            guard browserOmnibarShouldSubmitOnReturn(flags: event.modifierFlags) else { return false }
            parent.onSubmit(liveFieldSnapshot(preferredEditor: editor))
#if DEBUG
            handled = true
#endif
            return true
        case 53: // Escape
            parent.onEscape()
#if DEBUG
            handled = true
#endif
            return true
        case 125: // Down
            parent.onMoveSelection(+1)
#if DEBUG
            handled = true
#endif
            return true
        case 126: // Up
            parent.onMoveSelection(-1)
#if DEBUG
            handled = true
#endif
            return true
        case 124, 119: // Right arrow / End
            if parent.inlineCompletion != nil {
                parent.onAcceptInlineCompletion()
#if DEBUG
                handled = true
#endif
                return true
            }
        case 48: // Tab
            if parent.inlineCompletion != nil {
                parent.onAcceptInlineCompletion()
#if DEBUG
                handled = true
#endif
                return true
            }
        case 51: // Backspace
            if modifiers.contains(.command) || modifiers.contains(.option) {
                return false
            }
            if let inline = parent.inlineCompletion,
               inlineCompletionSelectionIsActive(editor, inline: inline) {
                parent.onDeleteBackwardWithInlineSelection()
#if DEBUG
                handled = true
#endif
                return true
            }
        default:
            break
        }

        return false
    }
}
