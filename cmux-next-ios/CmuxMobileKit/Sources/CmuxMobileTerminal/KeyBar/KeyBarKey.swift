import Foundation

/// A key of the key row (classic cmux iOS's accessory toolbar, SPEC 10.2).
enum KeyBarKey: Hashable, Sendable {
    case escape, tab, returnKey, control, alternate, command, shift
    case up, down, left, right, home, end, pageUp, pageDown
    case paste, zoomOut, zoomIn
    /// The pinned compose key: opens, focuses or closes the composer (`ComposerDockState`).
    case composer
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
        case .paste, .zoomOut, .zoomIn, .composer: ""
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
        case .paste, .zoomOut, .zoomIn, .composer: true
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

    var isLauncher: Bool {
        if case .launcher = self { true } else { false }
    }
}

/// Where the scroller puts the arrows and the agent launchers. Leo,
/// 2026-11-21: "dont move the arrow keys all the way left per se ofc just...
/// move them left of the weird claude/codex/ollama (why do we have
/// ollama!?) buttons...". Then, 2026-11-22, on the launchers sitting right
/// after the arrows: "surely we can think of more ergonomic ways to do
/// things...?", and he picked option B of the debate (cmux#50880): the
/// launchers go last, after a hairline, so nothing but keys is next to the
/// arrows.
public enum KeyBarLayout: String, CaseIterable, Sendable {
    /// The arrows right before the agent launchers (after ^C ^D): the
    /// default until 2026-11-22.
    case arrowsBeforeAgents
    /// The arrows right after Esc, before Return, ^C and ^D.
    case arrowsAfterEscape
    /// The default (option B): the terminal keys, then the zoom keys, then
    /// the agent launchers at the very end, after a hairline.
    case agentsLast

    /// The layout the app uses.
    public static let standard: KeyBarLayout = .agentsLast

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
        case .arrowsBeforeAgents: "Arrows right before the agents"
        case .arrowsAfterEscape: "Arrows after Esc"
        case .agentsLast: "Agents last, after a hairline (default)"
        }
    }

    /// The key the launchers' hairline is drawn before: the first launcher,
    /// unless it starts the row.
    var launcherSeparatorKey: KeyBarKey? {
        let row = scroller
        guard let first = row.firstIndex(where: \.isLauncher), first > 0 else { return nil }
        return row[first]
    }

    /// The scrolling keys. The keyboard key is pinned at the trailing edge,
    /// not in the scroller (one hide control). Built once per layout: the
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
        let zoom: [KeyBarKey] = [.zoomOut, .zoomIn]
        return switch self {
        case .arrowsBeforeAgents: modifiers + chords + KeyBarKey.arrows + agents + tail + zoom
        case .arrowsAfterEscape: modifiers + KeyBarKey.arrows + chords + agents + tail + zoom
        case .agentsLast: modifiers + chords + KeyBarKey.arrows + tail + zoom + agents
        }
    }
}

/// The key row's agent launchers (classic cmux iOS): each types its command
/// line. A tap only types it; the long-press menu's Run Now also presses
/// Return (`KeyBarLauncherTap`).
enum KeyBarLauncher: String, Hashable, Sendable {
    case claude, codex, ollama

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }

    /// What the key types.
    var command: String {
        switch self {
        case .claude: "claude --dangerously-skip-permissions"
        case .codex: "codex --yolo -c model_reasoning_effort=xhigh --search"
        case .ollama: "ollama run "
        }
    }

    /// What a tap (`.insert`) or Run Now (`.run`) sends. A tap never presses
    /// Return: one stray thumb used to run `claude --dangerously-skip-permissions`
    /// in whatever directory the pane was in (cmux#50880).
    func input(_ tap: KeyBarLauncherTap, router: TerminalInputRouter) -> [TerminalInputAction] {
        let typed: [TerminalInputAction] = [.text(command)]
        guard tap == .run else { return typed }
        return typed + router.plainKey(usage: TerminalHIDUsage.enter)
    }
}

/// A launcher's two actions: a tap inserts its command; the long-press
/// menu's Run Now inserts it and presses Return.
enum KeyBarLauncherTap: Sendable {
    case insert, run
}
