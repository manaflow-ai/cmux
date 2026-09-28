public import Foundation

/// Chooses the keys a click on an agent key hint sends.
///
/// Codex and OpenCode render their hints from their own keymaps, so the
/// printed chord is what they listen for. Claude Code prints some hints with
/// their default chord; when the user rebound that action in
/// `~/.claude/keybindings.json`, the user's chord is sent instead.
public struct AgentKeyHintChordResolver: Sendable {
    /// The user's Claude Code keybindings; empty for other agents.
    public var claudeKeybindings: ClaudeCodeKeybindings

    public init(claudeKeybindings: ClaudeCodeKeybindings = .empty) {
        self.claudeKeybindings = claudeKeybindings
    }

    /// A Claude Code action a hint names, and the chord Claude prints for it by default.
    struct ClaudeAction {
        var actionPrefix: String
        var actionId: String
        var defaultKeys: [String]
    }

    static let claudeActions: [ClaudeAction] = [
        ClaudeAction(actionPrefix: "expand", actionId: "app:toggleTranscript", defaultKeys: ["ctrl+o"]),
        ClaudeAction(actionPrefix: "cycle", actionId: "chat:cycleMode", defaultKeys: ["shift+tab"]),
        ClaudeAction(actionPrefix: "run in background", actionId: "task:background", defaultKeys: ["ctrl+b"]),
        ClaudeAction(actionPrefix: "interrupt", actionId: "chat:cancel", defaultKeys: ["escape"]),
        ClaudeAction(actionPrefix: "amend", actionId: "confirm:nextField", defaultKeys: ["tab"]),
    ]

    /// Keys to send for `hint`, in order.
    public func keys(for hint: AgentKeyHint, agent: AgentKeyHintDetector.Agent) -> [String] {
        guard agent == .claudeCode else { return hint.keys }
        let action = hint.action.lowercased()
        // A printed chord other than the default was already rendered from
        // the user's bindings; only a default chord can be stale.
        guard let known = Self.claudeActions.first(where: { action.hasPrefix($0.actionPrefix) }),
              hint.keys == known.defaultKeys || hint.keys == known.defaultKeys + known.defaultKeys,
              let bound = claudeKeybindings.keysByAction[known.actionId], !bound.isEmpty,
              !bound.contains(known.defaultKeys) else {
            return hint.keys
        }
        guard let replacement = bound.first(where: { !$0.contains(where: AgentKeyHintDetector.isSignalChord) }) else {
            return hint.keys
        }
        // `ctrl+b ctrl+b to run in background` asks for the chord twice.
        let repeats = hint.keys.count / known.defaultKeys.count
        return Array(repeating: replacement, count: max(repeats, 1)).flatMap { $0 }
    }
}

/// Whether a left click on an agent key hint presses it.
public struct AgentKeyHintClickPolicy: Sendable, Equatable {
    /// Whether the agent has captured the mouse.
    public var mouseCaptured: Bool
    /// Whether Command is held.
    public var commandHeld: Bool
    /// Whether Shift, Option, or Control is held.
    public var otherModifierHeld: Bool

    public init(mouseCaptured: Bool, commandHeld: Bool, otherModifierHeld: Bool) {
        self.mouseCaptured = mouseCaptured
        self.commandHeld = commandHeld
        self.otherModifierHeld = otherModifierHeld
    }

    /// A plain click presses a hint unless the agent has captured the mouse,
    /// in which case the click belongs to the agent and only a Command-click
    /// presses the hint. Shift, Option, and Control clicks keep their
    /// selection meanings.
    public var pressesHint: Bool {
        guard !otherModifierHeld else { return false }
        return commandHeld || !mouseCaptured
    }
}

extension String {
    /// The bytes a legacy terminal sends for the named key `keyName`, or `nil`
    /// when there is none. Used when the key's chord is taken by a terminal
    /// keybinding and can't travel as a key event.
    public init?(terminalLegacyEncodingOfNamedKey keyName: String) {
        guard let text = Self.terminalLegacyEncoding(ofNamedKey: keyName) else { return nil }
        self = text
    }

    private static func terminalLegacyEncoding(ofNamedKey keyName: String) -> String? {
        let name = keyName.lowercased().replacingOccurrences(of: "-", with: "+")
        switch name {
        case "escape", "esc": return "\u{1b}"
        case "tab": return "\t"
        case "shift+tab", "backtab": return "\u{1b}[Z"
        case "enter", "return": return "\r"
        case "space": return " "
        case "up": return "\u{1b}[A"
        case "down": return "\u{1b}[B"
        case "right": return "\u{1b}[C"
        case "left": return "\u{1b}[D"
        default: break
        }
        if name.hasPrefix("ctrl+"), name.count == 6, let letter = name.last,
           letter.isASCII, letter.isLetter, let ascii = letter.asciiValue {
            return String(UnicodeScalar(ascii & 0x1f))
        }
        if keyName.count == 1, let character = keyName.first, character.isASCII,
           !character.isWhitespace, let ascii = character.asciiValue, ascii >= 0x21, ascii < 0x7f {
            return keyName
        }
        return nil
    }
}
