import AppKit
import Carbon.HIToolbox
@testable import CmuxNextActions
import Foundation
import Testing

/// T2 of the input model (input-languages.md): every keyboard layout installed on this Mac
/// (`TISCreateInputSourceList`, all installed, not only the enabled ones) x virtual key codes
/// 0-127 x the modifier sets none, Shift, Option, Shift-Option, Control, Command. Each key is
/// read the way AppKit reports it, from the layout's own `UCKeyTranslate` data:
/// `characters` with the key's modifiers and dead-key state, `charactersIgnoringModifiers` with
/// Shift only, `characters(byApplyingModifiers: [])` and, with Command, `[.command]` (both
/// without dead keys, as AppKit's key-equivalent readings are), and, for a layout that is not
/// ASCII-capable, US ABC as the ASCII-capable layout (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`
/// on a new Mac).
///
/// It checks: (a) every default Command or Control chord runs its US action on every layout,
/// pressed on the key the layout puts its character on (a chord whose character the layout does
/// not type on any key is counted as unreachable, as in Ghostty, which matches the same way);
/// (b) a plain, Shift, Option or Shift-Option key is never a chord, and in a terminal resolves to
/// no shortcut, on any layout: it always reaches the input method and the terminal; (c) every
/// dead key composes with Space and starts no shortcut as a plain key. It prints one
/// `INPUT-LAYOUT-SWEEP` JSON line with the coverage: layouts x default chords passing (a), and
/// layouts x keys x the four non-chord modifier sets passing (b).
@MainActor @Suite struct KeyInputLayoutSweepTests {
    /// One installed keyboard layout.
    struct InstalledLayout {
        let id: String
        let asciiCapable: Bool
        let data: Data
    }

    /// The Carbon modifier key state UCKeyTranslate takes: `EventModifiers >> 8`.
    static func carbonState(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var state = 0
        if modifiers.contains(.shift) { state |= shiftKey }
        if modifiers.contains(.option) { state |= optionKey }
        if modifiers.contains(.control) { state |= controlKey }
        if modifiers.contains(.command) { state |= cmdKey }
        return UInt32(state >> 8) & 0xFF
    }

    /// What `keyCode` types on `layout` with `modifiers`; `deadKeyState` carries a dead key from
    /// the previous key (nil: translate without dead keys, as AppKit's key-equivalent readings do).
    static func translate(_ layout: Data, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, deadKeyState: inout UInt32?) -> String {
        layout.withUnsafeBytes { raw -> String in
            // SAFETY: `raw` is the layout's UCKeyboardLayout bytes (kTISPropertyUnicodeKeyLayoutData),
            // alive for this closure.
            guard let base = unsafe raw.baseAddress else { return "" }
            // SAFETY: as above.
            let keyboard = unsafe base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var state = deadKeyState ?? 0
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            let options = deadKeyState == nil ? OptionBits(1 << kUCKeyTranslateNoDeadKeysBit) : 0
            // SAFETY: `keyboard` is valid for this closure (above); UCKeyTranslate writes at most
            // chars.count units into `chars` and one count into `length`.
            let status = unsafe UCKeyTranslate(keyboard, keyCode, UInt16(kUCKeyActionDown), carbonState(modifiers), UInt32(LMGetKbdType()),
                                               options, &state, chars.count, &length, &chars)
            if deadKeyState != nil { deadKeyState = state }
            guard status == noErr, length > 0 else { return "" }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Every installed keyboard layout with layout data.
    static func installedLayouts() -> [InstalledLayout] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        // SAFETY: a Create function returns a +1 array (Create rule), taken over once here.
        guard let list = unsafe TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            // SAFETY: Get-rule properties owned by `source`, which `list` keeps alive; copied out here.
            guard let idPointer = unsafe TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let dataPointer = unsafe TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            // SAFETY: as above.
            let id = unsafe Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
            // SAFETY: as above.
            let data = unsafe Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
            var ascii = false
            // SAFETY: as above (a CFBoolean).
            if let pointer = unsafe TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) {
                // SAFETY: as above.
                ascii = CFBooleanGetValue(unsafe Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
            }
            return InstalledLayout(id: id, asciiCapable: ascii, data: data)
        }.sorted { $0.id < $1.id }
    }

    static let modifierSets: [NSEvent.ModifierFlags] = [[], [.shift], [.option], [.shift, .option], [.control], [.command]]

    /// The keys a layout maps to characters: the main block, virtual key codes 0x00-0x32 (with
    /// the ISO key 0x0A) without Return, Tab and Space. Codes 0x33-0x7F are Delete, Escape, the
    /// modifiers, the keypad, the function row and the arrows, which type the same everywhere.
    static let keyCodes: [UInt16] = (UInt16(0)...0x32).filter { ![kVK_Return, kVK_Tab, kVK_Space].contains(Int($0)) }

    /// The key as AppKit reports it on `layout`, read by ``KeyInput``.
    static func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, on layout: InstalledLayout, ascii: InstalledLayout?) -> KeyInput {
        var dead: UInt32? = 0
        var none: UInt32?
        let typed = translate(layout.data, keyCode: keyCode, modifiers: modifiers, deadKeyState: &dead)
        // AppKit's `characters` for a control character: Ghostty's host reads it again without Control.
        var text: String? = typed.isEmpty ? nil : typed
        if let scalar = typed.unicodeScalars.first, typed.unicodeScalars.count == 1, scalar.value < 0x20 {
            var noDead: UInt32?
            let again = translate(layout.data, keyCode: keyCode, modifiers: modifiers.subtracting(.control), deadKeyState: &noDead)
            text = again.isEmpty ? nil : again
        }
        let ignoring = translate(layout.data, keyCode: keyCode, modifiers: modifiers.intersection(.shift), deadKeyState: &none)
        let unshifted = translate(layout.data, keyCode: keyCode, modifiers: [], deadKeyState: &none)
        let command = modifiers.contains(.command) ? translate(layout.data, keyCode: keyCode, modifiers: [.command], deadKeyState: &none) : nil
        var fallback: String?
        if !modifiers.isDisjoint(with: [.command, .control]), !unshifted.allSatisfy(\.isASCII), let ascii {
            let latin = translate(ascii.data, keyCode: keyCode, modifiers: [], deadKeyState: &none).lowercased()
            if latin.count == 1, latin.allSatisfy({ $0.isASCII && !$0.isWhitespace }) { fallback = latin }
        }
        return KeyInput(keyCode: keyCode, modifiers: modifiers, text: text, ignoringModifiers: ignoring.isEmpty ? nil : ignoring,
                        unshifted: unshifted.isEmpty ? nil : unshifted, commandUnshifted: command.flatMap { $0.isEmpty ? nil : $0 },
                        asciiFallback: fallback)
    }

    /// The key the person presses for `shortcut` on `layout`: the digit row for a digit; with
    /// Command, the key whose Command map types the character; else the key that types it; on a
    /// layout that is not ASCII-capable, the key with the character on its Latin legend.
    static func keyCode(for shortcut: Shortcut, on layout: InstalledLayout, ascii: InstalledLayout?) -> UInt16? {
        if let digit = digitRow[shortcut.key] { return digit }
        var none: UInt32?
        func types(_ data: Data, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            translate(data, keyCode: code, modifiers: modifiers, deadKeyState: &none).lowercased() == shortcut.key
        }
        if shortcut.modifiers.contains(.command), let code = keyCodes.first(where: { types(layout.data, $0, [.command]) }) { return code }
        if let code = keyCodes.first(where: { types(layout.data, $0, []) }) { return code }
        guard !layout.asciiCapable, let ascii else { return nil }
        return keyCodes.first { types(ascii.data, $0, []) }
    }

    /// The digit row's key codes (kVK_ANSI_1 ... kVK_ANSI_0): a digit chord is pressed there on every layout.
    static let digitRow: [String: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    ]

    static func registry(_ context: ActionContext) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = context
        return registry
    }

    @Test func everyInstalledLayout() throws {
        let layouts = Self.installedLayouts()
        try #require(layouts.count > 20, "read only \(layouts.count) installed keyboard layouts")
        let us = try #require(layouts.first { $0.id == "com.apple.keylayout.US" }, "US layout not installed")
        let chordRegistry = Self.registry([])
        let terminalRegistry = Self.registry(.terminalFocused)
        let chords = KeyInputLayoutTests.defaultChords(in: chordRegistry)
        var expected: [Shortcut: ActionID] = [:]
        for shortcut in chords {
            guard let code = Self.keyCode(for: shortcut, on: us, ascii: nil),
                  let id = chordRegistry.resolveShortcut(for: Self.key(code, shortcut.modifiers, on: us, ascii: nil))?.id else { continue }
            expected[shortcut] = id
        }
        try #require(expected.count > 10, "only \(expected.count) default chords resolve on US")

        var chordsPassing = 0, chordsUnreachable = 0, keysPassing = 0, keysChecked = 0, deadKeys = 0, deadComposed = 0
        var failures: [String] = []
        var unreachable: [String: Int] = [:]
        for layout in layouts {
            let ascii = layout.asciiCapable ? nil : us
            // (a) every default chord.
            for (shortcut, id) in expected.sorted(by: { $0.key.displayString < $1.key.displayString }) {
                guard let code = Self.keyCode(for: shortcut, on: layout, ascii: ascii) else {
                    chordsUnreachable += 1
                    unreachable[shortcut.displayString, default: 0] += 1
                    continue
                }
                let key = Self.key(code, shortcut.modifiers, on: layout, ascii: ascii)
                let resolved = chordRegistry.resolveShortcut(for: key)?.id
                if resolved == id {
                    chordsPassing += 1
                } else {
                    failures.append("\(layout.id) \(shortcut.displayString) key \(code) text \(key.text ?? "nil"): \(resolved?.rawValue ?? "nothing"), not \(id)")
                }
            }
            // (b) plain and Option keys: never a chord, no shortcut in a terminal. (c) dead keys.
            for code in Self.keyCodes {
                for modifiers in Self.modifierSets where modifiers.isDisjoint(with: [.command, .control]) {
                    keysChecked += 1
                    let key = Self.key(code, modifiers, on: layout, ascii: ascii)
                    if let stolen = terminalRegistry.resolveShortcut(for: key)?.id, !key.isChord {
                        failures.append("\(layout.id) key \(code) mods \(modifiers.rawValue) types \(key.text ?? "nil"): taken by \(stolen)")
                    } else if key.isChord {
                        failures.append("\(layout.id) key \(code) mods \(modifiers.rawValue) reads as a chord")
                    } else {
                        keysPassing += 1
                    }
                    var dead: UInt32? = 0
                    let typed = Self.translate(layout.data, keyCode: code, modifiers: modifiers, deadKeyState: &dead)
                    guard typed.isEmpty, let state = dead, state != 0 else { continue }
                    deadKeys += 1
                    var next: UInt32? = state
                    let composed = Self.translate(layout.data, keyCode: UInt16(kVK_Space), modifiers: [], deadKeyState: &next)
                    if !composed.isEmpty { deadComposed += 1 } else { failures.append("\(layout.id) dead key \(code) mods \(modifiers.rawValue) composes nothing with Space") }
                }
            }
        }
        let report: [String: Any] = [
            "layouts": layouts.count, "ascii_capable": layouts.filter(\.asciiCapable).count, "default_chords": expected.count,
            "chords_passing": chordsPassing, "chords_unreachable": chordsUnreachable, "keys_checked": keysChecked,
            "keys_passing": keysPassing, "dead_keys": deadKeys, "dead_composed": deadComposed, "failures": failures.count,
            "unreachable_by_chord": unreachable, "first_failures": Array(failures.prefix(40)),
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("INPUT-LAYOUT-SWEEP \(String(decoding: json, as: UTF8.self))")
        #expect(failures.isEmpty, "\(failures.count) failures; first: \(failures.prefix(20).joined(separator: "\n"))")
    }
}
