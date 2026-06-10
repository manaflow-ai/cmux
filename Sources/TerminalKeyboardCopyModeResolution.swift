import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Keyboard copy mode key resolution and indicator text
var terminalKeyboardCopyModeIndicatorText: String {
    String(localized: "ghostty.copy-mode.indicator", defaultValue: "vim")
}

private var terminalKeyTableIndicatorDefaultText: String {
    String(localized: "ghostty.key-table.indicator", defaultValue: "key table")
}

var terminalKeyTableIndicatorAccessibilityLabel: String {
    String(localized: "ghostty.key-table.icon.accessibility", defaultValue: "Key table")
}

func terminalKeyTableIndicatorText(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "", "set":
        return terminalKeyTableIndicatorDefaultText
    case "vi", "vim":
        return terminalKeyboardCopyModeIndicatorText
    default:
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? terminalKeyTableIndicatorDefaultText : normalized
    }
}

private func terminalKeyboardCopyModeModifiers(
    _ modifierFlags: NSEvent.ModifierFlags
) -> TerminalKeyboardCopyModeModifiers {
    let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: TerminalKeyboardCopyModeModifiers = []
    if normalized.contains(.command) {
        modifiers.insert(.command)
    }
    if normalized.contains(.shift) {
        modifiers.insert(.shift)
    }
    if normalized.contains(.control) {
        modifiers.insert(.control)
    }
    if normalized.contains(.numericPad) {
        modifiers.insert(.numericPad)
    }
    if normalized.contains(.function) {
        modifiers.insert(.function)
    }
    if normalized.contains(.capsLock) {
        modifiers.insert(.capsLock)
    }
    return modifiers
}

func terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeShouldBypassForShortcut(
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags)
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
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags),
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
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags),
        hasSelection: hasSelection,
        state: &state,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

