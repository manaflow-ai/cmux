import AppKit
import CmuxTerminal
import CmuxTerminalCopyMode
import CmuxTerminalCore

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

func terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeShouldBypassForShortcut(
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags)
    )
}

func terminalKeyboardSelectionMoveForCommandEquivalent(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
) -> TerminalKeyboardCopyModeSelectionMove? {
    CmuxTerminalCopyMode.terminalKeyboardSelectionMoveForCommandEquivalent(
        keyCode: keyCode,
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags)
    )
}

func terminalKeyboardCopyModeAction(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeAction? {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeAction(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags),
        hasSelection: hasSelection,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

func terminalKeyboardCopyModeResolve(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    state: inout TerminalKeyboardCopyModeInputState,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeResolution {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeResolve(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags),
        hasSelection: hasSelection,
        state: &state,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

extension TerminalSurface {
    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }

    func debugInitialInputForTesting() -> String? {
        initialInput
    }
}
