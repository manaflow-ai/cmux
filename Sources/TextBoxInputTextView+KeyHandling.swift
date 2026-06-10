import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Key & Mouse Handling
extension TextBoxInputTextView {
    private static let localControlKeys: Set<String> = ["a", "e", "f", "b", "n", "p", "k", "h"]
    override func mouseDown(with event: NSEvent) {
        dismissMentionCompletions()
        if let hit = inlineAttachmentHit(for: event) {
            window?.makeFirstResponder(self)
            if hit.closeRect.contains(hit.point) {
                deleteAttachment(at: hit.characterIndex)
                return
            }
            selectAttachment(at: hit.characterIndex)
            if event.clickCount >= 2 {
                showAttachmentPreview(hit.attachment, characterIndex: hit.characterIndex)
            }
            return
        }
        clearAttachmentFocus(dismissPreview: true)
        super.mouseDown(with: event)
    }

    func handleInlineAttachmentCellClick(
        attachment: TextBoxAttachment,
        characterIndex: Int,
        clickCount: Int,
        isCloseClick: Bool
    ) {
        window?.makeFirstResponder(self)
        if isCloseClick {
            deleteAttachment(at: characterIndex)
            return
        }

        selectAttachment(at: characterIndex)
        if clickCount >= 2 {
            showAttachmentPreview(attachment, characterIndex: characterIndex)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if handleConfiguredTextBoxShortcut(event) {
            return true
        }
        if handleStandardEditShortcut(event) {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              !flags.contains(.control),
              textBoxCommandShortcutKey(for: event) == "z" else {
            return super.performKeyEquivalent(with: event)
        }

        if flags.contains(.shift) {
            guard undoManager?.canRedo == true else { return true }
            undoManager?.redo()
            synchronizeAfterUndoRedo()
            return true
        }

        guard undoManager?.canUndo == true else { return true }
        undoManager?.undo()
        synchronizeAfterUndoRedo()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleConfiguredTextBoxShortcut(event) {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let eventHasMarkedText = hasMarkedText()

        if !eventHasMarkedText,
           handleMentionCompletionKeyEvent(event) {
            return
        }

        if handleFocusedAttachmentKeyEvent(event) {
            return
        }

        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            if eventHasMarkedText {
                super.keyDown(with: event)
                return
            }
            if flags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(self)
            } else {
                submitIfAllowed()
            }
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            if eventHasMarkedText {
                super.keyDown(with: event)
                return
            }
            onEscape()
            return
        }

        if shouldHandleTextBoxPlainArrowLocally(
            keyCode: event.keyCode,
            firstResponderHasMarkedText: eventHasMarkedText,
            flags: flags
        ) {
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                moveInsertionPointLeft()
                return
            case kVK_RightArrow:
                moveInsertionPointRight()
                return
            case kVK_UpArrow:
                super.moveUp(self)
                return
            case kVK_DownArrow:
                super.moveDown(self)
                return
            default:
                break
            }
        }

        if flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           let key = controlKey(for: event) {
            if Self.localControlKeys.contains(key) {
                super.keyDown(with: event)
            } else {
                onForwardControl(key)
            }
            return
        }

        if string.isEmpty,
           !flags.contains(.command),
           !flags.contains(.option),
           let char = event.characters,
           char.count == 1,
           TextBoxAgentDetection.supportsAgentPrefixes(context: terminalTitle) {
            switch char {
            case "?":
                onForwardText(char, false)
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    override func doCommand(by commandSelector: Selector) {
        if hasMarkedText() {
            super.doCommand(by: commandSelector)
            return
        }

        if handleMentionCompletionCommand(commandSelector) {
            return
        }

        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            insertNewlineIgnoringFieldEditor(self)
            return
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitIfAllowed()
            return
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if isAttachmentPreviewShown {
                dismissAttachmentPreview()
                return
            }
            onEscape()
            return
        }

        switch commandSelector {
        case #selector(NSResponder.deleteBackward(_:)):
            if deleteAttachmentForKeyboardCommand(direction: .backward) {
                return
            }
        case #selector(NSResponder.deleteForward(_:)):
            if deleteAttachmentForKeyboardCommand(direction: .forward) {
                return
            }
        case #selector(NSResponder.moveLeft(_:)):
            if moveFocusedAttachmentSelection(toTrailingEdge: false) {
                return
            }
            moveInsertionPointLeft()
            return
        case #selector(NSResponder.moveRight(_:)):
            if moveFocusedAttachmentSelection(toTrailingEdge: true) {
                return
            }
            moveInsertionPointRight()
            return
        case #selector(NSResponder.moveBackward(_:)):
            moveInsertionPointLeft()
            return
        case #selector(NSResponder.moveForward(_:)):
            moveInsertionPointRight()
            return
        case #selector(NSResponder.moveUp(_:)):
            super.moveUp(self)
            return
        case #selector(NSResponder.moveDown(_:)):
            super.moveDown(self)
            return
        default:
            break
        }

        if string.isEmpty {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                onForwardKey(.tab)
                return
            case #selector(NSResponder.deleteBackward(_:)):
                onForwardKey(.backspace)
                return
            default:
                break
            }
        }

        super.doCommand(by: commandSelector)
    }

    func submitIfAllowed() {
        guard !hasPendingAttachmentUploadPlaceholder() else {
            NSSound.beep()
            return
        }
        guard hasSubmittableContent() else {
            NSSound.beep()
            return
        }
        onSubmit()
    }

    private func synchronizeAfterUndoRedo() {
        normalizeTextBaselineOffsets()
        recenterSingleLineTextContainer()
        didChangeText()
        refreshMentionCompletions()
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        window?.viewsNeedDisplay = true
    }

    private func handleConfiguredTextBoxShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !KeyboardShortcutRecorderActivity.isAnyRecorderActive else {
            return false
        }
        if KeyboardShortcutSettings.shortcut(for: .focusTextBoxInput).matches(event: event) {
            onToggleFocus()
            return true
        }
        if KeyboardShortcutSettings.shortcut(for: .attachTextBoxFile).matches(event: event) {
            onChooseFiles()
            return true
        }
        return false
    }

    private func handleStandardEditShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }

        switch textBoxCommandShortcutKey(for: event) {
        case "c":
            copy(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "v":
            paste(nil)
            return true
        default:
            return false
        }
    }

    func controlKey(for event: NSEvent) -> String? {
        physicalControlKey(for: event) ?? event.charactersIgnoringModifiers?.lowercased()
    }

    private func physicalControlKey(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        case kVK_ANSI_Backslash: return "\\"
        default:
            return nil
        }
    }
}
