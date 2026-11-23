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
        // Shows or hides the text field (not "compose a new message").
        case .composer: "character.textbox"
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
        case .composer: "Text Field"
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

    /// The scrolling keys of the default layout.
    static var row: [KeyBarKey] { KeyBarLayout.standard.scroller }

    /// The arrow keys, in classic cmux iOS's order.
    static let arrows: [KeyBarKey] = [.up, .down, .left, .right]
}

/// Where the scroller puts the arrows. Leo, 2026-11-21: "dont move the arrow
/// keys all the way left per se ofc just... move them left of the weird
/// claude/codex/ollama (why do we have ollama!?) buttons...". Classic cmux
/// iOS's order put them after the agent launchers, 14 keys in.
public enum KeyBarLayout: String, CaseIterable, Sendable {
    /// A, the default: classic's order with the arrows moved to just before
    /// the agent launchers (after ^C ^D).
    case arrowsBeforeAgents
    /// B: the arrows right after Esc, before Return, ^C and ^D.
    case arrowsAfterEscape
    /// C: as A, with the agent launchers moved to the end of the row (before
    /// the zoom keys), so the terminal keys come first.
    case agentsLast

    /// The layout the app uses.
    public static let standard: KeyBarLayout = .arrowsBeforeAgents

    /// The layout the key row draws: `standard`, or in DEBUG builds the
    /// `-cmuxMobile.keyBarLayout arrowsBeforeAgents|arrowsAfterEscape|agentsLast`
    /// launch argument, to try each one in the app.
    public static var current: KeyBarLayout {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "cmuxMobile.keyBarLayout"),
           let layout = KeyBarLayout(rawValue: name) { return layout }
        #endif
        return standard
    }

    /// The gallery's caption.
    public var title: String {
        switch self {
        case .arrowsBeforeAgents: "A: arrows before the agents (default)"
        case .arrowsAfterEscape: "B: arrows after Esc"
        case .agentsLast: "C: arrows before the agents, agents last"
        }
    }

    /// The scrolling keys, ending in Hide Toolbar. Built once per layout: the
    /// same array every time lets SwiftUI skip the scroller's keys on a
    /// scroll frame (a new array each body would rebuild them all).
    var scroller: [KeyBarKey] {
        switch self {
        case .arrowsBeforeAgents: Self.arrowsBeforeAgentsRow
        case .arrowsAfterEscape: Self.arrowsAfterEscapeRow
        case .agentsLast: Self.agentsLastRow
        }
    }

    private static let arrowsBeforeAgentsRow = KeyBarLayout.arrowsBeforeAgents.makeScroller()
    private static let arrowsAfterEscapeRow = KeyBarLayout.arrowsAfterEscape.makeScroller()
    private static let agentsLastRow = KeyBarLayout.agentsLast.makeScroller()

    private func makeScroller() -> [KeyBarKey] {
        let agents: [KeyBarKey] = [.launcher(.claude), .launcher(.codex), .launcher(.ollama)]
        let modifiers: [KeyBarKey] = [.control, .alternate, .command, .shift, .paste, .tab, .escape]
        let chords: [KeyBarKey] = [.returnKey, .chord("c"), .chord("d")]
        let tail: [KeyBarKey] = [
            .chord("l"),
            .symbol("~"), .symbol("$"), .symbol("/"), .symbol("@"), .symbol("|"),
            .chord("z"),
            .home, .end, .pageUp, .pageDown,
        ]
        let end: [KeyBarKey] = [.zoomOut, .zoomIn, .hideChrome]
        return switch self {
        case .arrowsBeforeAgents: modifiers + chords + KeyBarKey.arrows + agents + tail + end
        case .arrowsAfterEscape: modifiers + KeyBarKey.arrows + chords + agents + tail + end
        case .agentsLast: modifiers + chords + KeyBarKey.arrows + tail + agents + end
        }
    }
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
