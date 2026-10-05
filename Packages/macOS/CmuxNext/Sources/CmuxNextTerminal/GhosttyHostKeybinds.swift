public import AppKit
import Carbon.HIToolbox
import GhosttyNextKit

/// Ghostty keybinds for window, tab and split actions (`goto_split:left`,
/// `new_split:right`, ...) as chords the app can match without a terminal.
///
/// Ghostty only sees keys while a terminal surface has the keyboard. A user
/// who binds `cmd+ctrl+h=goto_split:left` expects it in every pane, also
/// while a web page or the address bar has focus. The App folds these
/// chords into its one binding table (`GhosttyKeyBindingLayer`), routed to
/// the registry action the terminal path runs (`TerminalHostAction`).
///
/// The table is read from the loaded config with `ghostty_config_trigger`
/// (the reverse map, so one chord per action: the last one bound) and is
/// rebuilt on every config change.
public nonisolated struct GhosttyHostKeybind: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        /// Unshifted codepoint (`cmd+ctrl+h`).
        case unicode(UInt32)
        /// Carbon virtual key code of a physical key (`arrow_left`, `key_h`).
        case keyCode(UInt16)
    }

    public var key: Key
    /// Shift, Control, Option and Command only.
    public var modifiers: NSEvent.ModifierFlags
    public var action: TerminalHostAction

    public init(key: Key, modifiers: NSEvent.ModifierFlags, action: TerminalHostAction) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevant)
        self.action = action
    }

    static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Whether a key-down is this chord, the way Ghostty compares it
    /// (unshifted codepoint or physical key, and exact modifiers).
    public func matches(keyCode: UInt16, unshifted: String?, modifiers eventModifiers: NSEvent.ModifierFlags) -> Bool {
        guard eventModifiers.intersection(Self.relevant) == modifiers else { return false }
        switch key {
        case .keyCode(let code):
            return code == keyCode
        case .unicode(let scalar):
            guard let first = unshifted?.lowercased().unicodeScalars.first else { return false }
            return first.value == scalar
        }
    }

    public func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return matches(keyCode: event.keyCode, unshifted: event.characters(byApplyingModifiers: []), modifiers: event.modifierFlags)
    }

    /// Ghostty action strings the app routes, with their host actions.
    static let routable: [(String, TerminalHostAction)] = {
        var list: [(String, TerminalHostAction)] = [
            ("goto_split:left", .gotoSplit(.left)), ("goto_split:right", .gotoSplit(.right)),
            ("goto_split:up", .gotoSplit(.up)), ("goto_split:down", .gotoSplit(.down)),
            ("goto_split:previous", .gotoSplit(.previous)), ("goto_split:next", .gotoSplit(.next)),
            ("new_split:right", .newSplit(.right)), ("new_split:down", .newSplit(.down)),
            ("new_split:left", .newSplit(.left)), ("new_split:up", .newSplit(.up)),
            ("equalize_splits", .equalizeSplits), ("toggle_split_zoom", .toggleSplitZoom),
            ("new_tab", .newTab), ("previous_tab", .gotoTab(.previous)), ("next_tab", .gotoTab(.next)),
            ("last_tab", .gotoTab(.last)), ("move_tab:-1", .moveTab(-1)), ("move_tab:1", .moveTab(1)),
            ("new_window", .newWindow), ("toggle_fullscreen", .toggleFullscreen),
            ("toggle_command_palette", .toggleCommandPalette),
        ]
        for index in 1...9 { list.append(("goto_tab:\(index)", .gotoTab(.index(index)))) }
        return list
    }()

    /// Physical Ghostty keys the table understands, as Carbon key codes.
    static func keyCode(for key: ghostty_input_key_e) -> UInt16? {
        let letters: [ghostty_input_key_e: Int] = [
            GHOSTTY_KEY_A: kVK_ANSI_A, GHOSTTY_KEY_B: kVK_ANSI_B, GHOSTTY_KEY_C: kVK_ANSI_C, GHOSTTY_KEY_D: kVK_ANSI_D,
            GHOSTTY_KEY_E: kVK_ANSI_E, GHOSTTY_KEY_F: kVK_ANSI_F, GHOSTTY_KEY_G: kVK_ANSI_G, GHOSTTY_KEY_H: kVK_ANSI_H,
            GHOSTTY_KEY_I: kVK_ANSI_I, GHOSTTY_KEY_J: kVK_ANSI_J, GHOSTTY_KEY_K: kVK_ANSI_K, GHOSTTY_KEY_L: kVK_ANSI_L,
            GHOSTTY_KEY_M: kVK_ANSI_M, GHOSTTY_KEY_N: kVK_ANSI_N, GHOSTTY_KEY_O: kVK_ANSI_O, GHOSTTY_KEY_P: kVK_ANSI_P,
            GHOSTTY_KEY_Q: kVK_ANSI_Q, GHOSTTY_KEY_R: kVK_ANSI_R, GHOSTTY_KEY_S: kVK_ANSI_S, GHOSTTY_KEY_T: kVK_ANSI_T,
            GHOSTTY_KEY_U: kVK_ANSI_U, GHOSTTY_KEY_V: kVK_ANSI_V, GHOSTTY_KEY_W: kVK_ANSI_W, GHOSTTY_KEY_X: kVK_ANSI_X,
            GHOSTTY_KEY_Y: kVK_ANSI_Y, GHOSTTY_KEY_Z: kVK_ANSI_Z,
            GHOSTTY_KEY_DIGIT_0: kVK_ANSI_0, GHOSTTY_KEY_DIGIT_1: kVK_ANSI_1, GHOSTTY_KEY_DIGIT_2: kVK_ANSI_2,
            GHOSTTY_KEY_DIGIT_3: kVK_ANSI_3, GHOSTTY_KEY_DIGIT_4: kVK_ANSI_4, GHOSTTY_KEY_DIGIT_5: kVK_ANSI_5,
            GHOSTTY_KEY_DIGIT_6: kVK_ANSI_6, GHOSTTY_KEY_DIGIT_7: kVK_ANSI_7, GHOSTTY_KEY_DIGIT_8: kVK_ANSI_8,
            GHOSTTY_KEY_DIGIT_9: kVK_ANSI_9,
            GHOSTTY_KEY_BRACKET_LEFT: kVK_ANSI_LeftBracket, GHOSTTY_KEY_BRACKET_RIGHT: kVK_ANSI_RightBracket,
            GHOSTTY_KEY_MINUS: kVK_ANSI_Minus, GHOSTTY_KEY_EQUAL: kVK_ANSI_Equal, GHOSTTY_KEY_COMMA: kVK_ANSI_Comma,
            GHOSTTY_KEY_PERIOD: kVK_ANSI_Period, GHOSTTY_KEY_SLASH: kVK_ANSI_Slash, GHOSTTY_KEY_SEMICOLON: kVK_ANSI_Semicolon,
            GHOSTTY_KEY_QUOTE: kVK_ANSI_Quote, GHOSTTY_KEY_BACKSLASH: kVK_ANSI_Backslash, GHOSTTY_KEY_BACKQUOTE: kVK_ANSI_Grave,
            GHOSTTY_KEY_ARROW_LEFT: kVK_LeftArrow, GHOSTTY_KEY_ARROW_RIGHT: kVK_RightArrow,
            GHOSTTY_KEY_ARROW_UP: kVK_UpArrow, GHOSTTY_KEY_ARROW_DOWN: kVK_DownArrow,
            GHOSTTY_KEY_ENTER: kVK_Return, GHOSTTY_KEY_TAB: kVK_Tab, GHOSTTY_KEY_SPACE: kVK_Space,
            GHOSTTY_KEY_BACKSPACE: kVK_Delete, GHOSTTY_KEY_DELETE: kVK_ForwardDelete,
            GHOSTTY_KEY_HOME: kVK_Home, GHOSTTY_KEY_END: kVK_End, GHOSTTY_KEY_PAGE_UP: kVK_PageUp, GHOSTTY_KEY_PAGE_DOWN: kVK_PageDown,
        ]
        return letters[key].map { UInt16($0) }
    }

    /// Reads the table from a finalized config.
    static func read(from config: ghostty_config_t) -> [GhosttyHostKeybind] {
        routable.compactMap { name, action in
            let trigger = name.withCString { ghostty_config_trigger(config, $0, UInt(name.utf8.count)) }
            let modifiers = GhosttyInput.flags(trigger.mods)
            switch trigger.tag {
            case GHOSTTY_TRIGGER_UNICODE:
                guard trigger.key.unicode != 0 else { return nil }
                return GhosttyHostKeybind(key: .unicode(trigger.key.unicode), modifiers: modifiers, action: action)
            case GHOSTTY_TRIGGER_PHYSICAL:
                guard trigger.key.physical != GHOSTTY_KEY_UNIDENTIFIED, let code = keyCode(for: trigger.key.physical) else { return nil }
                return GhosttyHostKeybind(key: .keyCode(code), modifiers: modifiers, action: action)
            default:
                return nil
            }
        }
    }
}

extension GhosttyRuntime {
    /// The routable Ghostty keybinds of the current config.
    public var hostKeybinds: [GhosttyHostKeybind] {
        if let cached = hostKeybindCache.binds { return cached }
        let binds = config.map(GhosttyHostKeybind.read(from:)) ?? []
        hostKeybindCache.binds = binds
        return binds
    }

    /// The routable keybinds of a config without the user's files:
    /// Ghostty's defaults with cmux's (`cmuxDefaultKeybindLines`) over them.
    /// A loaded keybind equal to one of these is a default, not the user's
    /// (GHOSTTY-CONFIG: cmux defaults beat Ghostty defaults; the user's
    /// Ghostty keybinds beat cmux defaults in a terminal). Read once.
    public var defaultHostKeybinds: [GhosttyHostKeybind] {
        if let cached = hostKeybindCache.defaults { return cached }
        guard config != nil, let defaults = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(defaults) }
        Self.loadKeybindDefaults(into: defaults)
        ghostty_config_finalize(defaults)
        let binds = GhosttyHostKeybind.read(from: defaults)
        hostKeybindCache.defaults = binds
        return binds
    }
}

/// Memo of `GhosttyRuntime.hostKeybinds` (cleared on every config change)
/// and of `defaultHostKeybinds` (kept: the defaults never change).
final class HostKeybindCache {
    var binds: [GhosttyHostKeybind]?
    var defaults: [GhosttyHostKeybind]?
}
