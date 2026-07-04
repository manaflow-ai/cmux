#if canImport(UIKit)
import CmuxMobileTerminalKit
import Foundation
import UIKit

public enum TerminalInputAccessoryAction: Int, CaseIterable, Sendable {
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
    /// Paste the system clipboard into the terminal: an image is forwarded to
    /// the Mac as `terminal.paste_image`, plain text rides the normal input
    /// path. Unlike the other actions it carries no fixed byte ``output``; the
    /// host reads the pasteboard when it is tapped.
    case paste
    /// Toggle the iMessage-style composer band above the terminal.
    ///
    /// Appended at the end so existing persisted raw values (user accessory bar
    /// order/enabled set) are preserved.
    case composer
    /// Send a carriage return (Enter). Appended at the end so existing persisted
    /// raw values (which are the `Int` rawValues, stored as `builtin.<n>`) stay
    /// stable; its default on-bar position is curated separately in
    /// ``defaultConfigurableOrder``.
    case returnKey
    /// Short label rendered on the terminal accessory button.
    public var title: String {
        title(isMacRemote: false)
    }

    /// Short label rendered on the terminal accessory button for the remote kind.
    /// - Parameter isMacRemote: Whether the target terminal is a macOS remote.
    /// - Returns: The compact title used by the accessory bar.
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
        case .composer:
            return ""
        case .escape:
            return String(localized: "terminal.input_accessory.title.escape", defaultValue: "Esc")
        case .tab:
            return String(localized: "terminal.input_accessory.title.tab", defaultValue: "Tab")
        case .returnKey:
            return "⏎"
        case .ctrlC:
            return "^C"
        case .ctrlD:
            return "^D"
        case .ctrlZ:
            return "^Z"
        case .ctrlL:
            return String(localized: "terminal.input_accessory.title.clear", defaultValue: "Clear")
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
        case .paste:
            return ""
        }
    }

    /// Stable accessibility identifier used by the terminal accessory button.
    public var accessibilityIdentifier: String {
        switch self {
        case .control: return "terminal.inputAccessory.control"
        case .alternate: return "terminal.inputAccessory.alt"
        case .command: return "terminal.inputAccessory.command"
        case .shift: return "terminal.inputAccessory.shift"
        case .zoomOut: return "terminal.inputAccessory.zoomOut"
        case .zoomIn: return "terminal.inputAccessory.zoomIn"
        case .composer: return "terminal.inputAccessory.composer"
        case .escape: return "terminal.inputAccessory.escape"
        case .tab: return "terminal.inputAccessory.tab"
        case .returnKey: return "terminal.inputAccessory.return"
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
        case .paste: return "terminal.inputAccessory.paste"
        }
    }

    /// VoiceOver label for icon-only accessory actions.
    public var accessibilityLabel: String? {
        switch self {
        case .zoomOut:
            return String(localized: "terminal.input_accessory.zoom_out", defaultValue: "Zoom Out")
        case .zoomIn:
            return String(localized: "terminal.input_accessory.zoom_in", defaultValue: "Zoom In")
        case .paste:
            return String(localized: "terminal.input_accessory.paste", defaultValue: "Paste")
        case .composer:
            return String(localized: "terminal.input_accessory.composer", defaultValue: "Composer")
        default:
            return nil
        }
    }

    /// SF Symbol name for icon-only accessory actions.
    public var symbolName: String? {
        switch self {
        case .zoomOut:
            return "minus.magnifyingglass"
        case .zoomIn:
            return "plus.magnifyingglass"
        case .paste:
            return "doc.on.clipboard"
        case .composer:
            return "square.and.pencil"
        default:
            return nil
        }
    }

    var zoomDirection: TerminalFontZoomDirection? {
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

    public var output: Data? {
        switch self {
        case .control, .alternate, .command, .shift, .zoomOut, .zoomIn, .paste, .composer:
            return nil
        case .escape:
            return Data([0x1B])
        case .tab:
            return Data([0x09])
        case .returnKey:
            return Data([0x0D]) // CR (Enter)
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
            return Data("codex --yolo -c model_reasoning_effort=xhigh --search\r".utf8)
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

    /// Whether the user can show/hide/reorder this action.
    ///
    /// Every button is configurable except ``composer`` (the iMessage-style
    /// composer toggle, pinned outside the scroll view, not a normal shortcut).
    /// The leading modifiers (⌃ ⌥ ⌘ ⇧), zoom, and paste were once structurally
    /// pinned but now move freely. ⇧ became configurable in this build;
    /// ``TerminalAccessoryConfiguration`` folds it into existing layouts.
    public var isUserConfigurable: Bool {
        switch self {
        case .composer:
            return false
        default:
            return true
        }
    }

    /// Every user-configurable action in canonical (enum) order. This is the full
    /// set the settings editor lists and the valid identifier set; it is *not* the
    /// default on-bar arrangement (see ``defaultConfigurableOrder``).
    public static var configurableActions: [TerminalInputAccessoryAction] {
        allCases.filter { $0.isUserConfigurable }
    }

    /// The modifier/paste controls leading the default bar: ⌃ ⌥ ⌘ ⇧ then paste
    /// (⇧ right after ⌘ so all four modifiers are adjacent). The v1/v2→v3 migration
    /// force-enables and prepends them, so an upgrading user keeps these controls
    /// and gains ⇧.
    public static var defaultLeadingActions: [TerminalInputAccessoryAction] {
        [.control, .alternate, .command, .shift, .paste]
    }

    /// The configurable actions that previously sat in the bar's fixed trailing
    /// region (the zoom controls). They tail ``defaultConfigurableOrder`` on a
    /// fresh install, and the migration force-enables and appends them so an
    /// upgrading user's bar looks unchanged.
    public static var defaultTrailingActions: [TerminalInputAccessoryAction] {
        [.zoomOut, .zoomIn]
    }

    /// The default on-bar arrangement of the configurable shortcuts: the leading
    /// modifier/paste controls, then the high-traffic agent and control keys (Tab,
    /// Esc, Return, ^C/^D, the Claude/Codex launchers, the arrow keys, Clear), then
    /// the punctuation and navigation keys, then the trailing zoom controls. Esc and
    /// Return sit immediately to the right of Tab so the most common terminal keys
    /// are adjacent. Curated independently of the enum's `rawValue` order so the
    /// default bar can be arranged without perturbing the persisted identifiers,
    /// which are the `rawValue`s.
    ///
    /// Must stay a permutation of ``configurableActions``;
    /// ``TerminalAccessoryLayoutReducer`` defensively appends any omission, so a
    /// gap here can never drop an action from the bar.
    public static var defaultConfigurableOrder: [TerminalInputAccessoryAction] {
        defaultLeadingActions + [
            .tab,
            .escape,
            .returnKey,
            .ctrlC, .ctrlD,
            .claude, .codex,
            .upArrow, .downArrow, .leftArrow, .rightArrow,
            .ctrlL,
            .tilde, .dollar, .slash, .atSign, .pipe,
            .ctrlZ,
            .home, .end, .pageUp, .pageDown,
        ] + defaultTrailingActions
    }

    /// Human-readable name for the shortcuts settings editor (the bar itself
    /// renders the short `title`/symbol).
    public var settingsDisplayName: String {
        switch self {
        case .escape: return String(localized: "terminal.shortcut.name.escape", defaultValue: "Escape")
        case .tab: return String(localized: "terminal.shortcut.name.tab", defaultValue: "Tab")
        case .returnKey: return String(localized: "terminal.shortcut.name.return", defaultValue: "Return")
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
        case .ctrlL: return String(localized: "terminal.shortcut.name.ctrlL", defaultValue: "Clear (Control-L)")
        case .home: return String(localized: "terminal.shortcut.name.home", defaultValue: "Home")
        case .end: return String(localized: "terminal.shortcut.name.end", defaultValue: "End")
        case .pageUp: return String(localized: "terminal.shortcut.name.pageUp", defaultValue: "Page Up")
        case .pageDown: return String(localized: "terminal.shortcut.name.pageDown", defaultValue: "Page Down")
        case .paste: return String(localized: "terminal.input_accessory.paste", defaultValue: "Paste")
        case .control: return String(localized: "terminal.shortcut.name.control", defaultValue: "Control")
        case .alternate: return String(localized: "terminal.shortcut.name.alternate", defaultValue: "Option")
        case .command: return String(localized: "terminal.shortcut.name.command", defaultValue: "Command")
        case .zoomIn: return String(localized: "terminal.input_accessory.zoom_in", defaultValue: "Zoom In")
        case .zoomOut: return String(localized: "terminal.input_accessory.zoom_out", defaultValue: "Zoom Out")
        case .shift: return String(localized: "terminal.shortcut.name.shift", defaultValue: "Shift")
        case .composer:
            return title
        }
    }
}
#endif
