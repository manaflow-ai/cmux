import AppKit
import Bonsplit
import Carbon
import SwiftUI


struct ShortcutStroke: Equatable, Hashable {
    enum RecordingResult: Equatable {
        case accepted(ShortcutStroke)
        case rejected(KeyboardShortcutSettings.ShortcutRecordingRejection)
        case unsupportedKey
    }

    private struct RecordableKey {
        let key: String
        let keyCode: UInt16?
    }

    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var keyCode: UInt16?

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
    }

    var displayString: String {
        modifierDisplayString + keyDisplayString
    }

    var modifierDisplayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }

    var keyDisplayString: String {
        switch key {
        case "\t":
            return String(localized: "shortcut.key.tab", defaultValue: "Tab")
        case "space": return String(localized: "shortcut.key.space", defaultValue: "Space")
        case "\r":
            return "↩"
        case "media.brightnessDown":
            return String(localized: "shortcut.key.mediaBrightnessDown", defaultValue: "Brightness Down")
        case "media.brightnessUp":
            return String(localized: "shortcut.key.mediaBrightnessUp", defaultValue: "Brightness Up")
        case "media.mute":
            return String(localized: "shortcut.key.mediaMute", defaultValue: "Mute")
        case "media.next":
            return String(localized: "shortcut.key.mediaNext", defaultValue: "Next Track")
        case "media.playPause":
            return String(localized: "shortcut.key.mediaPlayPause", defaultValue: "Play/Pause")
        case "media.previous":
            return String(localized: "shortcut.key.mediaPrevious", defaultValue: "Previous Track")
        case "media.volumeDown":
            return String(localized: "shortcut.key.mediaVolumeDown", defaultValue: "Volume Down")
        case "media.volumeUp":
            return String(localized: "shortcut.key.mediaVolumeUp", defaultValue: "Volume Up")
        default:
            if let functionKeyDisplayString = Self.functionKeyDisplayString(for: key) {
                return functionKeyDisplayString
            }
            return key.uppercased()
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var hasPrimaryModifier: Bool {
        command || option || control
    }

    var keyEquivalent: KeyEquivalent? {
        if key == "space" { return KeyEquivalent(Character(" ")) }

        if Self.usesDirectKeyCodeMatching(key) {
            return nil
        }

        switch key {
        case "←":
            return .leftArrow
        case "→":
            return .rightArrow
        case "↑":
            return .upArrow
        case "↓":
            return .downArrow
        case "\t":
            return .tab
        case "\r":
            return KeyEquivalent(Character("\r"))
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if command {
            modifiers.insert(.command)
        }
        if shift {
            modifiers.insert(.shift)
        }
        if option {
            modifiers.insert(.option)
        }
        if control {
            modifiers.insert(.control)
        }
        return modifiers
    }

    var menuItemKeyEquivalent: String? {
        if key == "space" { return " " }

        if Self.usesDirectKeyCodeMatching(key) {
            return nil
        }

        switch key {
        case "←":
            guard let scalar = UnicodeScalar(NSLeftArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "→":
            guard let scalar = UnicodeScalar(NSRightArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↑":
            guard let scalar = UnicodeScalar(NSUpArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↓":
            guard let scalar = UnicodeScalar(NSDownArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "\t":
            return "\t"
        case "\r":
            return "\r"
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    static func isEscapeCancelEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }

        if event.keyCode == 53 {
            return true
        }

        let escapeScalar = UnicodeScalar(0x1B)!
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let shouldTreatEscapeCharacterAsCancel = normalizedFlags.isEmpty || event.keyCode == 36 || event.keyCode == 76

        if shouldTreatEscapeCharacterAsCancel,
           event.characters?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        if shouldTreatEscapeCharacterAsCancel,
           event.charactersIgnoringModifiers?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        return false
    }

    static func from(event: NSEvent, requireModifier: Bool = true) -> ShortcutStroke? {
        guard case let .accepted(stroke) = recordingResult(from: event, requireModifier: requireModifier) else {
            return nil
        }
        return stroke
    }

    static func recordingResult(
        from event: NSEvent,
        requireModifier: Bool = true
    ) -> RecordingResult {
        guard !isEscapeCancelEvent(event),
              let recordableKey = recordableKey(from: event) else {
            return .unsupportedKey
        }

        let flags = normalizedModifierFlags(from: event.modifierFlags)

        let stroke = ShortcutStroke(
            key: recordableKey.key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            keyCode: recordableKey.keyCode
        )

        if requireModifier,
           !stroke.command && !stroke.shift && !stroke.option && !stroke.control &&
           !stroke.isBareShortcutAllowedWithoutModifier {
            return .rejected(.bareKeyNotAllowed)
        }
        return .accepted(stroke)
    }

    static func normalizedModifierFlags(from flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    func matches(
        event: NSEvent,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        let shortcutKey = key.lowercased()
        if shortcutKey.hasPrefix("media.") {
            guard let eventMediaKey = Self.mediaKey(from: event)?.key.lowercased() else {
                return false
            }
            return eventMediaKey == shortcutKey &&
                Self.normalizedModifierFlags(from: event.modifierFlags) == modifierFlags
        }

        guard event.type == .keyDown else { return false }
        if shortcutRoutingShouldBypassForPrintableOptionText(event: event) {
            return false
        }

        return matches(
            keyCode: Self.recordableKey(from: event)?.keyCode ?? event.keyCode,
            modifierFlags: event.modifierFlags,
            eventCharacter: event.charactersIgnoringModifiers,
            layoutCharacterProvider: layoutCharacterProvider
        )
    }

    func matches(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventCharacter: String?,
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> Bool {
        let flags = Self.normalizedModifierFlags(from: modifierFlags)
        guard flags == self.modifierFlags else { return false }

        let shortcutKey = key.lowercased()
        if Self.usesDirectKeyCodeMatching(shortcutKey) {
            guard let expectedKeyCode = self.keyCode ?? Self.keyCodeForShortcutKey(shortcutKey) else {
                return false
            }
            return keyCode == expectedKeyCode
        }

        if shortcutKey == "\r" {
            return keyCode == 36 || keyCode == 76
        }

        if Self.shortcutCharacterMatches(
            eventCharacter: eventCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: keyCode
        ) {
            return true
        }

        let hasEventChars = !(eventCharacter?.isEmpty ?? true)
        let eventCharsAreASCII = eventCharacter?.allSatisfy(\.isASCII) ?? true
        let eventCharsArePrintableASCII = eventCharacter?.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && !CharacterSet.controlCharacters.contains(scalar)
        } ?? true
        let shortcutKeyIsDigit = shortcutKey.count == 1 && shortcutKey.first?.isNumber == true
        let shortcutKeyIsLetter = shortcutKey.count == 1 && shortcutKey.first?.isLetter == true
        let eventCharacterIsLetterOrNumber = eventCharacter?.count == 1 &&
            (eventCharacter?.first?.isLetter == true || eventCharacter?.first?.isNumber == true)
        let commandPrintableCharacterShouldBlockFallback = flags.contains(.command) &&
            hasEventChars &&
            eventCharsArePrintableASCII &&
            (!flags.contains(.control) || !shortcutKeyIsLetter) &&
            (shortcutKeyIsLetter || eventCharacterIsLetterOrNumber)
        if shortcutKeyIsDigit,
           hasEventChars,
           eventCharsAreASCII,
           Self.digitForNumberKeyCode(keyCode) == nil {
            return false
        }
        if commandPrintableCharacterShouldBlockFallback {
            return false
        }

        let layoutCharacter = layoutCharacterProvider(keyCode, modifierFlags)
        if Self.shortcutCharacterMatches(
            eventCharacter: layoutCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: false,
            eventKeyCode: keyCode
        ) {
            return true
        }

        let allowANSIKeyCodeFallback = flags.contains(.control)
            || (flags.contains(.command)
                && !flags.contains(.control)
                && (
                    !Self.shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey)
                        || (hasEventChars && !eventCharsAreASCII)
                        || (!hasEventChars && (layoutCharacter?.isEmpty ?? true))
                ))
        if allowANSIKeyCodeFallback,
           let expectedKeyCode = Self.keyCodeForShortcutKey(shortcutKey) {
            return keyCode == expectedKeyCode
        }

        return false
    }

    private var isBareShortcutAllowedWithoutModifier: Bool {
        Self.usesDirectKeyCodeMatching(key)
    }

    private static func recordableKey(from event: NSEvent) -> RecordableKey? {
        if event.type == .systemDefined {
            return mediaKey(from: event)
        }

        guard event.type == .keyDown || event.type == .keyUp else {
            return nil
        }

        if let specialKey = event.specialKey,
           let recordableKey = recordableKey(from: specialKey, eventKeyCode: event.keyCode) {
            return recordableKey
        }

        guard let storedKey = storedKey(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return nil
        }
        return RecordableKey(key: storedKey, keyCode: event.keyCode)
    }

    private static func storedKey(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?
    ) -> String? {
        // Prefer keyCode mapping so shifted symbol keys (e.g. "}") record as "]".
        switch keyCode {
        case 123: return "←" // left arrow
        case 124: return "→" // right arrow
        case 125: return "↓" // down arrow
        case 126: return "↑" // up arrow
        case 48: return "\t" // tab
        case 49: return "space" // kVK_Space
        case 36, 76: return "\r" // return, keypad enter
        case 33: return "["  // kVK_ANSI_LeftBracket
        case 30: return "]"  // kVK_ANSI_RightBracket
        case 27: return "-"  // kVK_ANSI_Minus
        case 24: return "="  // kVK_ANSI_Equal
        case 43: return ","  // kVK_ANSI_Comma
        case 47: return "."  // kVK_ANSI_Period
        case 44: return "/"  // kVK_ANSI_Slash
        case 41: return ";"  // kVK_ANSI_Semicolon
        case 39: return "'"  // kVK_ANSI_Quote
        case 50: return "`"  // kVK_ANSI_Grave
        case 42: return "\\" // kVK_ANSI_Backslash
        default:
            break
        }

        guard let chars = charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else {
            return nil
        }

        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }

    private static func recordableKey(
        from specialKey: NSEvent.SpecialKey,
        eventKeyCode: UInt16
    ) -> RecordableKey? {
        switch specialKey {
        case .f1: return RecordableKey(key: "f1", keyCode: eventKeyCode)
        case .f2: return RecordableKey(key: "f2", keyCode: eventKeyCode)
        case .f3: return RecordableKey(key: "f3", keyCode: eventKeyCode)
        case .f4: return RecordableKey(key: "f4", keyCode: eventKeyCode)
        case .f5: return RecordableKey(key: "f5", keyCode: eventKeyCode)
        case .f6: return RecordableKey(key: "f6", keyCode: eventKeyCode)
        case .f7: return RecordableKey(key: "f7", keyCode: eventKeyCode)
        case .f8: return RecordableKey(key: "f8", keyCode: eventKeyCode)
        case .f9: return RecordableKey(key: "f9", keyCode: eventKeyCode)
        case .f10: return RecordableKey(key: "f10", keyCode: eventKeyCode)
        case .f11: return RecordableKey(key: "f11", keyCode: eventKeyCode)
        case .f12: return RecordableKey(key: "f12", keyCode: eventKeyCode)
        case .f13: return RecordableKey(key: "f13", keyCode: eventKeyCode)
        case .f14: return RecordableKey(key: "f14", keyCode: eventKeyCode)
        case .f15: return RecordableKey(key: "f15", keyCode: eventKeyCode)
        case .f16: return RecordableKey(key: "f16", keyCode: eventKeyCode)
        case .f17: return RecordableKey(key: "f17", keyCode: eventKeyCode)
        case .f18: return RecordableKey(key: "f18", keyCode: eventKeyCode)
        case .f19: return RecordableKey(key: "f19", keyCode: eventKeyCode)
        case .f20: return RecordableKey(key: "f20", keyCode: eventKeyCode)
        default:
            return nil
        }
    }

    private static func mediaKey(from event: NSEvent) -> RecordableKey? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == Int16(8) else {
            return nil
        }

        let data1 = UInt32(truncatingIfNeeded: event.data1)
        let keyCode = UInt16((data1 & 0xFFFF0000) >> 16)
        let keyState = UInt8((data1 & 0x0000FF00) >> 8)
        guard keyState == 0x0A else { return nil }

        switch keyCode {
        case 0: return RecordableKey(key: "media.volumeUp", keyCode: keyCode)
        case 1: return RecordableKey(key: "media.volumeDown", keyCode: keyCode)
        case 2: return RecordableKey(key: "media.brightnessUp", keyCode: keyCode)
        case 3: return RecordableKey(key: "media.brightnessDown", keyCode: keyCode)
        case 7: return RecordableKey(key: "media.mute", keyCode: keyCode)
        case 16: return RecordableKey(key: "media.playPause", keyCode: keyCode)
        case 17: return RecordableKey(key: "media.next", keyCode: keyCode)
        case 18: return RecordableKey(key: "media.previous", keyCode: keyCode)
        default:
            return nil
        }
    }

    static func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()

        // "+" -> "=" and "_" -> "-" are normalized regardless of Shift. On US
        // layouts these symbols only exist as Shift variants, so the Shift gate
        // below historically sufficed. On European layouts (German QWERTZ, French
        // AZERTY, Nordic) "+" and "-" are dedicated keys typed WITHOUT Shift, so a
        // bare "+"/"_" can only originate from such a key. Mapping them to their
        // base zoom key ("=", "-") unconditionally is therefore safe (no shortcut
        // key is ever stored as "+"/"_") and is what makes Cmd zoom work there.
        switch lowered {
        case "+": return "="
        case "_": return "-"
        default: break
        }

        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    private static func shouldRequireCharacterMatchForCommandShortcut(shortcutKey: String) -> Bool {
        guard shortcutKey.count == 1, let scalar = shortcutKey.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    private static func shortcutCharacterMatches(
        eventCharacter: String?,
        shortcutKey: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Bool {
        guard let eventCharacter, !eventCharacter.isEmpty else { return false }
        return normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        ) == shortcutKey
    }

    private static func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        switch key {
        case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111
        case "f13": return 105
        case "f14": return 107
        case "f15": return 113
        case "f16": return 106
        case "f17": return 64
        case "f18": return 79
        case "f19": return 80
        case "f20": return 90
        case "media.volumeUp": return 0
        case "media.volumeDown": return 1
        case "media.brightnessUp": return 2
        case "media.brightnessDown": return 3
        case "media.mute": return 7
        case "media.playPause": return 16
        case "media.next": return 17
        case "media.previous": return 18
        case "space": return 49
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "\t": return 48
        case "`": return 50
        case "\r": return 36
        case "←": return 123
        case "→": return 124
        case "↓": return 125
        case "↑": return 126
        default:
            return nil
        }
    }

    private static func usesDirectKeyCodeMatching(_ key: String) -> Bool {
        key == "space" || functionKeyDisplayString(for: key) != nil || key.hasPrefix("media.")
    }

    private static func functionKeyDisplayString(for key: String) -> String? {
        guard key.hasPrefix("f"),
              let number = Int(key.dropFirst()),
              (1...20).contains(number) else {
            return nil
        }
        return "F\(number)"
    }

    private static func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default:
            return nil
        }
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if command { modifiers |= UInt32(cmdKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        if option { modifiers |= UInt32(optionKey) }
        if control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    func resolvedKeyCode(
        layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) -> UInt16? {
        if let keyCode {
            return keyCode
        }

        let shortcutKey = key.lowercased()
        let flags = modifierFlags
        let applyShiftNormalization = flags.contains(.shift)

        for candidateKeyCode in Self.supportedShortcutKeyCodes {
            let candidateCharacter = layoutCharacterProvider(candidateKeyCode, flags)
            if Self.shortcutCharacterMatches(
                eventCharacter: candidateCharacter,
                shortcutKey: shortcutKey,
                applyShiftSymbolNormalization: applyShiftNormalization,
                eventKeyCode: candidateKeyCode
            ) {
                return candidateKeyCode
            }
        }

        return Self.keyCodeForShortcutKey(shortcutKey)
    }

    var carbonHotKeyRegistration: CarbonHotKeyRegistration? {
        guard let keyCode = resolvedKeyCode() else { return nil }
        return CarbonHotKeyRegistration(keyCode: UInt32(keyCode), modifiers: carbonModifiers)
    }

    private static let supportedShortcutKeyCodes: [UInt16] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
        50, 123, 124, 125, 126,
    ]
}

