import Foundation

/// A key of the key row (classic cmux iOS's accessory toolbar, SPEC 10.2).
enum KeyBarKey: Hashable, Sendable {
    case escape, tab, returnKey, control, alternate, command, shift
    case up, down, left, right, home, end, pageUp, pageDown
    case paste, zoomOut, zoomIn
    /// The pinned compose key: opens, focuses or closes the composer (`ComposerDockState`).
    case composer
    /// Hides the key row, the composer and the keyboard until the next terminal tap.
    case hideChrome
    case chord(Character)
    case symbol(String)
    case launcher(KeyBarLauncher)

    var label: String {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .returnKey: "⏎"
        // The phone always drives a Mac's terminal: Mac modifier glyphs (classic).
        case .control: "⌃"
        case .alternate: "⌥"
        case .command: "⌘"
        case .shift: "⇧"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .paste, .zoomOut, .zoomIn, .composer, .hideChrome: ""
        case .chord("l"): "Clear"
        case .chord(let letter): "^" + String(letter).uppercased()
        case .symbol(let text): text
        case .launcher(let launcher): launcher.title
        }
    }

    /// The SF Symbol of an icon key.
    var symbolName: String? {
        switch self {
        case .paste: "doc.on.clipboard"
        case .zoomOut: "minus.magnifyingglass"
        case .zoomIn: "plus.magnifyingglass"
        case .composer: "square.and.pencil"
        case .hideChrome: "chevron.down.square"
        default: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .returnKey: "Return"
        case .control: "Control"
        case .alternate: "Option"
        case .command: "Command"
        case .shift: "Shift"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .paste: "Paste"
        case .zoomOut: "Zoom Out"
        case .zoomIn: "Zoom In"
        case .composer: "Composer"
        case .hideChrome: "Hide Toolbar"
        case .chord("l"): "Clear (Control-L)"
        case .chord(let letter): "Control " + String(letter).uppercased()
        case .symbol(let text): text
        case .launcher(let launcher): launcher.title
        }
    }

    /// A stable accessibility identifier suffix (`terminal.key.<id>`).
    var identifier: String {
        switch self {
        case .escape: "escape"
        case .tab: "tab"
        case .returnKey: "return"
        case .control: "control"
        case .alternate: "alt"
        case .command: "command"
        case .shift: "shift"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .home: "home"
        case .end: "end"
        case .pageUp: "page-up"
        case .pageDown: "page-down"
        case .paste: "paste"
        case .zoomOut: "zoom-out"
        case .zoomIn: "zoom-in"
        case .composer: "composer"
        case .hideChrome: "hide-chrome"
        case .chord(let letter): "ctrl-" + String(letter).lowercased()
        case .symbol(let text): "symbol-" + text.unicodeScalars.map { String($0.value) }.joined(separator: "-")
        case .launcher(let launcher): "launcher-" + launcher.rawValue
        }
    }

    /// Arrows repeat while held.
    var repeats: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }

    /// A one-glyph key (modifiers, arrows, icons) is exactly `KeyRowMetrics.minKeyWidth`
    /// wide; a word key hugs its label (classic).
    var isGlyph: Bool {
        switch self {
        case .control, .alternate, .command, .shift, .up, .down, .left, .right, .returnKey: true
        case .paste, .zoomOut, .zoomIn, .composer, .hideChrome: true
        case .symbol: true
        default: false
        }
    }

    var modifier: TerminalStickyModifiers.Modifier? {
        switch self {
        case .control: .control
        case .alternate: .alternate
        case .command: .command
        case .shift: .shift
        default: nil
        }
    }

    /// The scrolling keys, in classic cmux iOS's default order
    /// (`TerminalInputAccessoryAction.defaultConfigurableOrder`), ending in Hide Toolbar.
    static let row: [KeyBarKey] = [
        .control, .alternate, .command, .shift, .paste,
        .tab, .escape, .returnKey,
        .chord("c"), .chord("d"),
        .launcher(.claude), .launcher(.codex), .launcher(.ollama),
        .up, .down, .left, .right,
        .chord("l"),
        .symbol("~"), .symbol("$"), .symbol("/"), .symbol("@"), .symbol("|"),
        .chord("z"),
        .home, .end, .pageUp, .pageDown,
        .zoomOut, .zoomIn,
        .hideChrome,
    ]
}

/// The key row's agent launchers (classic cmux iOS): each types its command line.
enum KeyBarLauncher: String, Hashable, Sendable {
    case claude, codex, ollama

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }

    /// What the key types. Claude and Codex run at once; Ollama waits for the
    /// model name, so it has no Return.
    var command: String {
        switch self {
        case .claude: "claude --dangerously-skip-permissions"
        case .codex: "codex --yolo -c model_reasoning_effort=xhigh --search"
        case .ollama: "ollama run "
        }
    }

    var pressesReturn: Bool { self != .ollama }
}
