public import GhosttyKit

extension GhosttyTriggerPhysicalKey {
    /// Maps a GhosttyKit C physical key (`ghostty_input_key_e`) onto the
    /// shortcut-key token.
    ///
    /// This is the GhosttyKit-boundary translation; CmuxTerminalCore re-vends the
    /// GhosttyKit binary target, so the C symbols are visible here alongside the
    /// glyphs and decode rules. Returns `nil` for any key cmux does not render
    /// as a goto-split shortcut, matching the original switch's `default` branch.
    public init?(ghosttyPhysicalKey physical: ghostty_input_key_e) {
        switch physical {
        case GHOSTTY_KEY_ARROW_LEFT: self = .arrowLeft
        case GHOSTTY_KEY_ARROW_RIGHT: self = .arrowRight
        case GHOSTTY_KEY_ARROW_UP: self = .arrowUp
        case GHOSTTY_KEY_ARROW_DOWN: self = .arrowDown
        case GHOSTTY_KEY_A: self = .a
        case GHOSTTY_KEY_B: self = .b
        case GHOSTTY_KEY_C: self = .c
        case GHOSTTY_KEY_D: self = .d
        case GHOSTTY_KEY_E: self = .e
        case GHOSTTY_KEY_F: self = .f
        case GHOSTTY_KEY_G: self = .g
        case GHOSTTY_KEY_H: self = .h
        case GHOSTTY_KEY_I: self = .i
        case GHOSTTY_KEY_J: self = .j
        case GHOSTTY_KEY_K: self = .k
        case GHOSTTY_KEY_L: self = .l
        case GHOSTTY_KEY_M: self = .m
        case GHOSTTY_KEY_N: self = .n
        case GHOSTTY_KEY_O: self = .o
        case GHOSTTY_KEY_P: self = .p
        case GHOSTTY_KEY_Q: self = .q
        case GHOSTTY_KEY_R: self = .r
        case GHOSTTY_KEY_S: self = .s
        case GHOSTTY_KEY_T: self = .t
        case GHOSTTY_KEY_U: self = .u
        case GHOSTTY_KEY_V: self = .v
        case GHOSTTY_KEY_W: self = .w
        case GHOSTTY_KEY_X: self = .x
        case GHOSTTY_KEY_Y: self = .y
        case GHOSTTY_KEY_Z: self = .z
        case GHOSTTY_KEY_DIGIT_0: self = .digit0
        case GHOSTTY_KEY_DIGIT_1: self = .digit1
        case GHOSTTY_KEY_DIGIT_2: self = .digit2
        case GHOSTTY_KEY_DIGIT_3: self = .digit3
        case GHOSTTY_KEY_DIGIT_4: self = .digit4
        case GHOSTTY_KEY_DIGIT_5: self = .digit5
        case GHOSTTY_KEY_DIGIT_6: self = .digit6
        case GHOSTTY_KEY_DIGIT_7: self = .digit7
        case GHOSTTY_KEY_DIGIT_8: self = .digit8
        case GHOSTTY_KEY_DIGIT_9: self = .digit9
        case GHOSTTY_KEY_BRACKET_LEFT: self = .bracketLeft
        case GHOSTTY_KEY_BRACKET_RIGHT: self = .bracketRight
        case GHOSTTY_KEY_MINUS: self = .minus
        case GHOSTTY_KEY_EQUAL: self = .equal
        case GHOSTTY_KEY_COMMA: self = .comma
        case GHOSTTY_KEY_PERIOD: self = .period
        case GHOSTTY_KEY_SLASH: self = .slash
        case GHOSTTY_KEY_SEMICOLON: self = .semicolon
        case GHOSTTY_KEY_QUOTE: self = .quote
        case GHOSTTY_KEY_BACKQUOTE: self = .backquote
        case GHOSTTY_KEY_BACKSLASH: self = .backslash
        default: return nil
        }
    }
}
