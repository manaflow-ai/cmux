public import AppKit

/// How a key event leaves the viewer (`remoteDesktop.keyboard.mode`).
public nonisolated enum RemoteKeyboardMode: String, Sendable, Hashable, CaseIterable, Codable {
    /// Physical keys while the input source can type ASCII, else text.
    case auto
    /// Every key as its HID usage; the host's layout decides the character.
    case physical
    /// Characters through the viewer's input method as Unicode text;
    /// keys that type nothing (arrows, Return, chords) stay physical.
    case text
}

/// The routing and containment rules for one key event. Pure: the capture
/// view asks it and acts on the answer.
public nonisolated enum RemoteKeyboardPolicy {
    public enum Route: Sendable, Equatable {
        /// Handle in the viewer (system and cmux shortcuts): never sent.
        case local
        /// Return the keyboard to the viewer (the release chord).
        case releaseKeyboard
        /// Send as a physical key.
        case physical
        /// Pass through the input method; committed text becomes `.text`.
        case textInput
    }

    /// Routes a key down. `isLocalShortcut` is the App's matcher for cmux
    /// shortcuts (KeyboardShortcutSettings); it applies only while system
    /// shortcuts stay local.
    public static func route(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        mode: RemoteKeyboardMode,
        sendSystemShortcuts: Bool,
        inputSourceIsASCIICapable: Bool,
        releaseChord: RemoteReleaseChord = .default,
        isLocalShortcut: Bool = false
    ) -> Route {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if releaseChord.matches(keyCode: keyCode, modifiers: flags) { return .releaseKeyboard }
        if !sendSystemShortcuts, isSystemShortcut(keyCode: keyCode, modifiers: flags) || isLocalShortcut {
            return .local
        }
        let textMode = switch mode {
        case .physical: false
        case .text: true
        case .auto: !inputSourceIsASCIICapable
        }
        guard textMode, typesText(keyCode: keyCode, modifiers: flags) else { return .physical }
        return .textInput
    }

    /// Chords the system or the window server owns: app switching, Spotlight
    /// and input source switching, Mission Control and Spaces, and the
    /// app-level Cmd-Q / Cmd-H / Cmd-M. cmux's own shortcuts (Cmd-W, Cmd-T
    /// ...) come from the App's matcher, so a rebinding follows the user.
    public static func isSystemShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        switch keyCode {
        case KeyCode.tab, KeyCode.grave:
            return flags.contains(.command)
        case KeyCode.space:
            return flags.contains(.command) || flags == .control
        case KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow:
            return flags == .control
        case KeyCode.missionControl, KeyCode.launchpad:
            return true
        case KeyCode.q, KeyCode.h, KeyCode.m:
            return flags == .command || flags == [.command, .option]
        default:
            return false
        }
    }

    /// Whether the key can produce text: no Command or Control, and not a
    /// navigation, editing or function key.
    public static func typesText(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if !modifiers.intersection([.command, .control]).isEmpty { return false }
        guard let usage = RemoteHIDKeyMap.usage(forKeyCode: keyCode) else { return false }
        let id = usage & 0xFFFF
        // Letters, digits, punctuation and space (0x04...0x38 minus the
        // editing keys), the non-US key, and the keypad's characters.
        switch id {
        case 0x28, 0x29, 0x2A, 0x2B: return false // return escape backspace tab
        case 0x04...0x38, 0x64, 0x85, 0x87, 0x89: return true
        case 0x54...0x57, 0x59...0x63, 0x67: return true
        default: return false
        }
    }

    enum KeyCode {
        static let tab: UInt16 = 0x30
        static let grave: UInt16 = 0x32
        static let space: UInt16 = 0x31
        static let escape: UInt16 = 0x35
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
        static let downArrow: UInt16 = 0x7D
        static let upArrow: UInt16 = 0x7E
        static let missionControl: UInt16 = 0xA0
        static let launchpad: UInt16 = 0x83
        static let q: UInt16 = 0x0C
        static let h: UInt16 = 0x04
        static let m: UInt16 = 0x2E
    }
}

/// The chord that always returns the keyboard to the viewer. Declared as a
/// value with a stable id so the App can register it in
/// KeyboardShortcutSettings (editable, in cmux.json) and pass the user's
/// binding back in.
public nonisolated struct RemoteReleaseChord: Sendable, Hashable {
    /// KeyboardShortcutSettings id.
    public static let shortcutID = "remoteDesktop.releaseKeyboard"
    /// Control-Option-Escape.
    public static let `default` = RemoteReleaseChord(keyCode: RemoteKeyboardPolicy.KeyCode.escape, modifiers: [.control, .option])

    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
    }

    public func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && modifiers.intersection([.command, .control, .option, .shift]) == self.modifiers
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}
