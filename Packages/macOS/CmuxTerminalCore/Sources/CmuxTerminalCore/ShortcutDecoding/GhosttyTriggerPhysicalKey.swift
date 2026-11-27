/// A physical keyboard key that Ghostty can bind a trigger to, restricted to the
/// keys cmux maps to a menu-style shortcut glyph.
///
/// The app target translates Ghostty's C `GHOSTTY_KEY_*` enum into one of these
/// cases at the call seam, so the decoding logic and its glyph table live in this
/// package without importing GhosttyKit. Any Ghostty physical key cmux does not
/// turn into a shortcut (modifiers, function keys, numpad keys, and so on) maps to
/// `nil` at the seam rather than to a case here, mirroring the original `default`
/// branch that returned no shortcut.
public enum GhosttyTriggerPhysicalKey: String, Sendable, Equatable, Hashable, CaseIterable {
    /// The left arrow key, rendered as `←`.
    case arrowLeft
    /// The right arrow key, rendered as `→`.
    case arrowRight
    /// The up arrow key, rendered as `↑`.
    case arrowUp
    /// The down arrow key, rendered as `↓`.
    case arrowDown
    /// The `A` letter key.
    case a
    /// The `B` letter key.
    case b
    /// The `C` letter key.
    case c
    /// The `D` letter key.
    case d
    /// The `E` letter key.
    case e
    /// The `F` letter key.
    case f
    /// The `G` letter key.
    case g
    /// The `H` letter key.
    case h
    /// The `I` letter key.
    case i
    /// The `J` letter key.
    case j
    /// The `K` letter key.
    case k
    /// The `L` letter key.
    case l
    /// The `M` letter key.
    case m
    /// The `N` letter key.
    case n
    /// The `O` letter key.
    case o
    /// The `P` letter key.
    case p
    /// The `Q` letter key.
    case q
    /// The `R` letter key.
    case r
    /// The `S` letter key.
    case s
    /// The `T` letter key.
    case t
    /// The `U` letter key.
    case u
    /// The `V` letter key.
    case v
    /// The `W` letter key.
    case w
    /// The `X` letter key.
    case x
    /// The `Y` letter key.
    case y
    /// The `Z` letter key.
    case z
    /// The `0` digit key.
    case digit0
    /// The `1` digit key.
    case digit1
    /// The `2` digit key.
    case digit2
    /// The `3` digit key.
    case digit3
    /// The `4` digit key.
    case digit4
    /// The `5` digit key.
    case digit5
    /// The `6` digit key.
    case digit6
    /// The `7` digit key.
    case digit7
    /// The `8` digit key.
    case digit8
    /// The `9` digit key.
    case digit9
    /// The left bracket key, rendered as `[`.
    case bracketLeft
    /// The right bracket key, rendered as `]`.
    case bracketRight
    /// The minus key, rendered as `-`.
    case minus
    /// The equal key, rendered as `=`.
    case equal
    /// The comma key, rendered as `,`.
    case comma
    /// The period key, rendered as `.`.
    case period
    /// The slash key, rendered as `/`.
    case slash
    /// The semicolon key, rendered as `;`.
    case semicolon
    /// The quote key, rendered as `'`.
    case quote
    /// The backquote key, rendered as `` ` ``.
    case backquote
    /// The backslash key, rendered as `\`.
    case backslash

    /// The menu-style glyph cmux renders for this physical key.
    ///
    /// These glyphs are byte-identical to the literals the original
    /// `storedShortcutFromGhosttyTrigger` switch produced for each `GHOSTTY_KEY_*`
    /// case.
    public var glyph: String {
        switch self {
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .a: return "a"
        case .b: return "b"
        case .c: return "c"
        case .d: return "d"
        case .e: return "e"
        case .f: return "f"
        case .g: return "g"
        case .h: return "h"
        case .i: return "i"
        case .j: return "j"
        case .k: return "k"
        case .l: return "l"
        case .m: return "m"
        case .n: return "n"
        case .o: return "o"
        case .p: return "p"
        case .q: return "q"
        case .r: return "r"
        case .s: return "s"
        case .t: return "t"
        case .u: return "u"
        case .v: return "v"
        case .w: return "w"
        case .x: return "x"
        case .y: return "y"
        case .z: return "z"
        case .digit0: return "0"
        case .digit1: return "1"
        case .digit2: return "2"
        case .digit3: return "3"
        case .digit4: return "4"
        case .digit5: return "5"
        case .digit6: return "6"
        case .digit7: return "7"
        case .digit8: return "8"
        case .digit9: return "9"
        case .bracketLeft: return "["
        case .bracketRight: return "]"
        case .minus: return "-"
        case .equal: return "="
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .semicolon: return ";"
        case .quote: return "'"
        case .backquote: return "`"
        case .backslash: return "\\"
        }
    }
}
