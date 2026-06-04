public import Foundation

/// One button on the terminal input-accessory bar (modifiers, zoom, and the
/// user-configurable shortcut inserts).
public enum TerminalInputAccessoryAction: Int, CaseIterable {
    case control
    case alternate
    case command
    case shift
    case zoomOut
    case zoomIn
    case escape
    case tab
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case claude
    case codex
    case tilde
    case pipe
    case dollar
    case slash
    case atSign
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL
    case home
    case end
    case pageUp
    case pageDown
    /// Short label rendered on the bar button (non-Mac-remote form).
    public var title: String {
        title(isMacRemote: false)
    }

    /// Short label rendered on the bar button. Mac remotes show the
    /// modifier glyphs (⌃ ⌥) instead of Ctrl/Alt text.
    public func title(isMacRemote: Bool) -> String {
        switch self {
        case .control:
            return isMacRemote ? "⌃" : String(localized: "terminal.input_accessory.title.control", defaultValue: "Ctrl")
        case .alternate:
            return isMacRemote ? "⌥" : String(localized: "terminal.input_accessory.title.alt", defaultValue: "Alt")
        case .command:
            return "⌘"
        case .shift:
            return "⇧"
        case .zoomOut:
            return ""
        case .zoomIn:
            return ""
        case .escape:
            return String(localized: "terminal.input_accessory.title.escape", defaultValue: "Esc")
        case .tab:
            return String(localized: "terminal.input_accessory.title.tab", defaultValue: "Tab")
        case .ctrlC:
            return "^C"
        case .ctrlD:
            return "^D"
        case .ctrlZ:
            return "^Z"
        case .ctrlL:
            return "^L"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .home:
            return String(localized: "terminal.input_accessory.title.home", defaultValue: "Home")
        case .end:
            return String(localized: "terminal.input_accessory.title.end", defaultValue: "End")
        case .pageUp:
            return String(localized: "terminal.input_accessory.title.pageUp", defaultValue: "PgUp")
        case .tilde:
            return "~"
        case .pipe:
            return "|"
        case .dollar:
            return "$"
        case .slash:
            return "/"
        case .atSign:
            return "@"
        case .pageDown:
            return String(localized: "terminal.input_accessory.title.pageDown", defaultValue: "PgDn")
        }
    }

    /// Stable XCUITest identifier for the bar button.
    public var accessibilityIdentifier: String {
        switch self {
        case .control: return "terminal.inputAccessory.control"
        case .alternate: return "terminal.inputAccessory.alt"
        case .command: return "terminal.inputAccessory.command"
        case .shift: return "terminal.inputAccessory.shift"
        case .zoomOut: return "terminal.inputAccessory.zoomOut"
        case .zoomIn: return "terminal.inputAccessory.zoomIn"
        case .escape: return "terminal.inputAccessory.escape"
        case .tab: return "terminal.inputAccessory.tab"
        case .upArrow: return "terminal.inputAccessory.up"
        case .downArrow: return "terminal.inputAccessory.down"
        case .leftArrow: return "terminal.inputAccessory.left"
        case .rightArrow: return "terminal.inputAccessory.right"
        case .claude: return "terminal.inputAccessory.claude"
        case .codex: return "terminal.inputAccessory.codex"
        case .tilde: return "terminal.inputAccessory.tilde"
        case .pipe: return "terminal.inputAccessory.pipe"
        case .dollar: return "terminal.inputAccessory.dollar"
        case .slash: return "terminal.inputAccessory.slash"
        case .atSign: return "terminal.inputAccessory.atSign"
        case .ctrlC: return "terminal.inputAccessory.ctrlC"
        case .ctrlD: return "terminal.inputAccessory.ctrlD"
        case .ctrlZ: return "terminal.inputAccessory.ctrlZ"
        case .ctrlL: return "terminal.inputAccessory.ctrlL"
        case .home: return "terminal.inputAccessory.home"
        case .end: return "terminal.inputAccessory.end"
        case .pageUp: return "terminal.inputAccessory.pageUp"
        case .pageDown: return "terminal.inputAccessory.pageDown"
        }
    }

    /// VoiceOver label, for symbol-only buttons.
    public var accessibilityLabel: String? {
        switch self {
        case .zoomOut:
            return String(localized: "terminal.input_accessory.zoom_out", defaultValue: "Zoom Out")
        case .zoomIn:
            return String(localized: "terminal.input_accessory.zoom_in", defaultValue: "Zoom In")
        default:
            return nil
        }
    }

    /// SF Symbol name, for the zoom buttons.
    public var symbolName: String? {
        switch self {
        case .zoomOut:
            return "minus.magnifyingglass"
        case .zoomIn:
            return "plus.magnifyingglass"
        default:
            return nil
        }
    }

    /// The zoom direction this action drives, for the zoom buttons.
    public var zoomDirection: TerminalFontZoomDirection? {
        switch self {
        case .zoomOut:
            return .decrease
        case .zoomIn:
            return .increase
        default:
            return nil
        }
    }

    /// Whether this action is a modifier key (toggleable armed state).
    public var isModifier: Bool {
        switch self {
        case .control, .alternate, .command, .shift: return true
        default: return false
        }
    }

    /// The VT byte sequence the action inserts, or `nil` for
    /// modifier/zoom controls.
    public var output: Data? {
        switch self {
        case .control, .alternate, .command, .shift, .zoomOut, .zoomIn:
            return nil
        case .escape:
            return Data([0x1B])
        case .tab:
            return Data([0x09])
        case .tilde:
            return Data([0x7E]) // ~
        case .pipe:
            return Data([0x7C]) // |
        case .dollar:
            return Data([0x24]) // $
        case .slash:
            return Data([0x2F]) // /
        case .atSign:
            return Data([0x40]) // @
        case .ctrlC:
            return Data([0x03])
        case .ctrlD:
            return Data([0x04])
        case .ctrlZ:
            return Data([0x1A])
        case .ctrlL:
            return Data([0x0C])
        case .upArrow:
            return Data([0x1B, 0x5B, 0x41]) // ESC[A
        case .downArrow:
            return Data([0x1B, 0x5B, 0x42]) // ESC[B
        case .leftArrow:
            return Data([0x1B, 0x5B, 0x44]) // ESC[D
        case .rightArrow:
            return Data([0x1B, 0x5B, 0x43]) // ESC[C
        case .claude:
            return Data("claude --dangerously-skip-permissions\r".utf8)
        case .codex:
            return Data("codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort=xhigh --search\r".utf8)
        case .home:
            return Data([0x1B, 0x5B, 0x48]) // ESC[H
        case .end:
            return Data([0x1B, 0x5B, 0x46]) // ESC[F
        case .pageUp:
            return Data([0x1B, 0x5B, 0x35, 0x7E]) // ESC[5~
        case .pageDown:
            return Data([0x1B, 0x5B, 0x36, 0x7E]) // ESC[6~
        }
    }

    /// Whether the user can show/hide/reorder this action. The modifier keys
    /// (⌃ ⌥ ⌘ ⇧) and zoom controls are structural and stay pinned, so only the
    /// insertable shortcuts (those with an `output`) are configurable.
    public var isUserConfigurable: Bool {
        output != nil && !isModifier
    }

    /// Every user-configurable action in canonical (enum) order. This is both
    /// the default arrangement and the full set the settings editor lists.
    public static var configurableActions: [TerminalInputAccessoryAction] {
        allCases.filter { $0.isUserConfigurable }
    }

    /// Human-readable name for the shortcuts settings editor (the bar itself
    /// renders the short `title`/symbol).
    public var settingsDisplayName: String {
        switch self {
        case .escape: return String(localized: "terminal.shortcut.name.escape", defaultValue: "Escape")
        case .tab: return String(localized: "terminal.shortcut.name.tab", defaultValue: "Tab")
        case .upArrow: return String(localized: "terminal.shortcut.name.upArrow", defaultValue: "Up Arrow")
        case .downArrow: return String(localized: "terminal.shortcut.name.downArrow", defaultValue: "Down Arrow")
        case .leftArrow: return String(localized: "terminal.shortcut.name.leftArrow", defaultValue: "Left Arrow")
        case .rightArrow: return String(localized: "terminal.shortcut.name.rightArrow", defaultValue: "Right Arrow")
        case .claude: return String(localized: "terminal.shortcut.name.claude", defaultValue: "Claude")
        case .codex: return String(localized: "terminal.shortcut.name.codex", defaultValue: "Codex")
        case .tilde: return String(localized: "terminal.shortcut.name.tilde", defaultValue: "Tilde ~")
        case .pipe: return String(localized: "terminal.shortcut.name.pipe", defaultValue: "Pipe |")
        case .dollar: return String(localized: "terminal.shortcut.name.dollar", defaultValue: "Dollar $")
        case .slash: return String(localized: "terminal.shortcut.name.slash", defaultValue: "Slash /")
        case .atSign: return String(localized: "terminal.shortcut.name.atSign", defaultValue: "At @")
        case .ctrlC: return String(localized: "terminal.shortcut.name.ctrlC", defaultValue: "Control-C")
        case .ctrlD: return String(localized: "terminal.shortcut.name.ctrlD", defaultValue: "Control-D")
        case .ctrlZ: return String(localized: "terminal.shortcut.name.ctrlZ", defaultValue: "Control-Z")
        case .ctrlL: return String(localized: "terminal.shortcut.name.ctrlL", defaultValue: "Control-L")
        case .home: return String(localized: "terminal.shortcut.name.home", defaultValue: "Home")
        case .end: return String(localized: "terminal.shortcut.name.end", defaultValue: "End")
        case .pageUp: return String(localized: "terminal.shortcut.name.pageUp", defaultValue: "Page Up")
        case .pageDown: return String(localized: "terminal.shortcut.name.pageDown", defaultValue: "Page Down")
        case .control, .alternate, .command, .shift, .zoomIn, .zoomOut:
            return title
        }
    }
}
