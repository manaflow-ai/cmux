import Foundation

/// A key of the key bar (SPEC 10.2).
enum KeyBarKey: Hashable, Sendable {
    case escape, tab, shiftTab, control, alternate, up, down, left, right, paste, hideKeyboard
    case chord(Character)
    case symbol(String)

    var label: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .shiftTab: "⇧tab"
        case .control: "ctrl"
        case .alternate: "alt"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .paste: "paste"
        case .hideKeyboard: ""
        case .chord(let letter): "^" + String(letter).uppercased()
        case .symbol(let text): text
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shiftTab: "Shift Tab"
        case .control: "Control"
        case .alternate: "Alt"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .paste: "Paste"
        case .hideKeyboard: "Hide Keyboard"
        case .chord(let letter): "Control " + String(letter).uppercased()
        case .symbol(let text): text
        }
    }

    /// A stable accessibility identifier suffix (`terminal.key.<id>`).
    var identifier: String {
        switch self {
        case .escape: "escape"
        case .tab: "tab"
        case .shiftTab: "shift-tab"
        case .control: "control"
        case .alternate: "alt"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .paste: "paste"
        case .hideKeyboard: "hide-keyboard"
        case .chord(let letter): "ctrl-" + String(letter).lowercased()
        case .symbol(let text): "symbol-" + text.unicodeScalars.map { String($0.value) }.joined(separator: "-")
        }
    }

    /// Arrows repeat while held.
    var repeats: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }

    /// Pinned at the leading end (SPEC B2): the two keys a shell needs most
    /// and the modifier, always on screen and always accessible.
    static let pinned: [KeyBarKey] = [.escape, .control, .chord("c")]

    /// The scroller, in order of use. `alt` is the rarest modifier and lives here.
    static let middle: [KeyBarKey] = [
        .tab, .shiftTab, .up, .down, .left, .right, .chord("d"), .chord("z"), .chord("l"), .alternate,
        .symbol("|"), .symbol("~"), .symbol("/"), .symbol("-"), .paste, .symbol("`"), .symbol("{"), .symbol("}"),
        .symbol("["), .symbol("]"), .chord("r"), .chord("b"),
    ]
}
