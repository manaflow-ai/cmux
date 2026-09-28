public import Foundation

/// A key hint an agent TUI printed, such as `ctrl+o to expand`.
public struct AgentKeyHint: Sendable, Equatable {
    /// Named keys to press, in order, in `TerminalSurface.sendNamedKey` form
    /// (`ctrl+o`, `shift+tab`, `escape`, `down`).
    public var keys: [String]
    /// What the hint says the keys do (`expand`, `run in background`).
    public var action: String
    /// Terminal cells the hint covers on its line, keys through action.
    public var columns: Range<Int>

    public init(keys: [String], action: String, columns: Range<Int>) {
        self.keys = keys
        self.action = action
        self.columns = columns
    }

    /// Whether the hint counts only in the agent's live region
    /// (``AgentKeyHintLiveRegion``): any of its keys lacks Ctrl and Alt.
    public var needsLiveRegion: Bool {
        keys.contains(where: AgentKeyHintDetector.needsLiveRegion)
    }
}

/// Finds agent key hints in one line of terminal text.
///
/// Grammar: one or more chords (`esc`, `tab`, `shift+tab`, `enter`, `space`,
/// arrows, `ctrl+x`, `alt+x`, `ctrl+x ctrl+k`), optionally `again`, then
/// `to` or `for`, then an action that ends at `·`, `•`, `|`, `(`, `)`, `,`,
/// two spaces, or the end of the line. OpenCode prints some hints without
/// `to` (`esc interrupt`), which match only for its known actions.
///
/// Chords that quit, suspend, or signal (`ctrl+c`, `ctrl+d`, `ctrl+z`,
/// `ctrl+\`, with or without Shift or Alt) are never returned.
///
/// Keys that act on whatever UI is live (Enter, Esc, Tab, arrows, bare
/// letters, Home, End, page keys) are returned only for a line in the
/// agent's live region (``AgentKeyHintLiveRegion``). The same words in
/// scrollback or in the agent's prose would press a key the live UI never
/// offered. Ctrl and Alt chords name one binding and count on any line.
public struct AgentKeyHintDetector: Sendable {
    public enum Agent: Sendable {
        case claudeCode
        case codex
        case openCode
    }

    /// The agent whose hints this detector reads.
    public let agent: Agent

    public init(agent: Agent) {
        self.agent = agent
    }

    /// Whether `key`, a normalized chord, quits, suspends, or signals: Ctrl
    /// with `c`, `d`, `z`, or `\`, whatever Shift or Alt is added, since the
    /// terminal still sends 0x03, 0x04, 0x1a, or 0x1c for those.
    static func isSignalChord(_ key: String) -> Bool {
        let parts = key.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count > 1, parts.dropLast().contains("ctrl"), let base = parts.last else { return false }
        return ["c", "d", "z", "\\"].contains(base)
    }

    /// Whether `key` counts only in the live region: anything without Ctrl or Alt.
    static func needsLiveRegion(_ key: String) -> Bool {
        let modifiers = key.split(separator: "+", omittingEmptySubsequences: false).dropLast()
        return !modifiers.contains("ctrl") && !modifiers.contains("alt")
    }

    // `return` is not a key word: agents print `enter` or `⏎`, and prose
    // says "return to" far more often than it names the key.
    private static let namedKeys: [String: String] = [
        "esc": "escape", "escape": "escape", "tab": "tab", "enter": "enter",
        "space": "space", "up": "up", "down": "down", "left": "left", "right": "right",
        "↑": "up", "↓": "down", "←": "left", "→": "right", "⏎": "enter", "↵": "enter",
        "backspace": "backspace", "delete": "delete", "pgup": "pageup", "pgdn": "pagedown",
        "pageup": "pageup", "pagedown": "pagedown", "home": "home", "end": "end",
    ]
    private static let modifiers: [String: String] = [
        "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl", "alt": "alt", "option": "alt", "opt": "alt",
        "meta": "alt", "shift": "shift", "⇧": "shift",
    ]
    private static let openCodeBareActions: Set<String> = ["interrupt", "exit", "cancel", "again to interrupt"]
    private static let actionTerminators: Set<Character> = ["·", "•", "|", "(", ")", ",", ";", "[", "]"]

    /// The hint covering `column`, if any.
    ///
    /// - Parameter inLiveRegion: Whether the line is in the agent's live
    ///   region. Outside it only Ctrl and Alt chords count.
    public func hint(in line: String, atColumn column: Int, inLiveRegion: Bool) -> AgentKeyHint? {
        hints(in: line, inLiveRegion: inLiveRegion).first { $0.columns.contains(column) }
    }

    /// Every hint on the line, left to right.
    ///
    /// - Parameter inLiveRegion: Whether the line is in the agent's live
    ///   region. Outside it only Ctrl and Alt chords count.
    public func hints(in line: String, inLiveRegion: Bool) -> [AgentKeyHint] {
        let cells = TerminalCellText(line)
        let words = cells.words
        var hints: [AgentKeyHint] = []
        var index = 0
        while index < words.count {
            guard let hint = hint(startingAt: index, words: words, cells: cells) else {
                index += 1
                continue
            }
            if inLiveRegion || !hint.hint.needsLiveRegion {
                hints.append(hint.hint)
            }
            index = hint.nextWord
        }
        return hints
    }

    private func hint(
        startingAt start: Int,
        words: [TerminalCellText.Word],
        cells: TerminalCellText
    ) -> (hint: AgentKeyHint, nextWord: Int)? {
        var keys: [String] = []
        var index = start
        while index < words.count, let key = Self.chord(words[index].text) {
            keys.append(key)
            index += 1
        }
        guard !keys.isEmpty, !keys.contains(where: Self.isSignalChord) else { return nil }
        let isStrongHint = keys.contains { Self.isStrong($0, printed: words[start].text) }
        if index < words.count, words[index].text.lowercased() == "again" {
            index += 1
        }
        let connector = index < words.count ? words[index].text.lowercased() : ""
        let actionStart: Int
        if connector == "to" || connector == "for" {
            actionStart = index + 1
        } else if agent == .openCode {
            actionStart = index
        } else {
            return nil
        }
        guard actionStart < words.count else { return nil }
        var actionEnd = actionStart
        while actionEnd < words.count {
            let word = words[actionEnd]
            if actionEnd > actionStart, cells.hasGapBefore(word) { break }
            if let first = word.text.first, Self.actionTerminators.contains(first) { break }
            actionEnd += 1
            if let last = word.text.last, Self.actionTerminators.contains(last) { break }
        }
        guard actionEnd > actionStart else { return nil }
        let action = words[actionStart..<actionEnd]
            .map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: "·•|(),;[]")) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty else { return nil }
        if connector != "to" && connector != "for" {
            guard Self.openCodeBareActions.contains(action.lowercased()) else { return nil }
        }
        // Bare key words and single characters read as prose (`end to end`,
        // `up to date`, `a to b`); they count only before a hint verb.
        // Modifier chords, Esc, and key glyphs always count.
        if !isStrongHint {
            let verb = action.split(separator: " ").first.map { $0.lowercased() } ?? ""
            guard Self.weakHintVerbs.contains(verb) else { return nil }
        }
        let first = words[start]
        let last = words[actionEnd - 1]
        var endColumn = last.columns.upperBound
        if let trailing = last.text.last, Self.actionTerminators.contains(trailing) {
            endColumn -= 1
        }
        var startColumn = first.columns.lowerBound
        if let leading = first.text.first, leading == "(" {
            startColumn += 1
        }
        return (AgentKeyHint(keys: keys, action: action, columns: startColumn..<endColumn), actionEnd)
    }

    private static let weakHintVerbs: Set<String> = [
        "accept", "amend", "approve", "cancel", "close", "collapse", "confirm", "continue", "cycle",
        "deny", "dismiss", "edit", "exit", "expand", "go", "interrupt", "manage", "navigate", "open",
        "queue", "quit", "reject", "retry", "scroll", "search", "select", "send", "shortcuts", "skip",
        "submit", "switch", "toggle", "view",
    ]
    private static let keyGlyphs: Set<Character> = ["↑", "↓", "←", "→", "⏎", "↵", "⇥", "⌃", "⇧"]

    private static func isStrong(_ key: String, printed: String) -> Bool {
        key.contains("+") || key == "escape"
            || printed.contains { keyGlyphs.contains($0) }
    }

    /// Normalizes one printed chord (`ctrl+o`, `Shift+Tab`, `⌃O`, `esc`) to a
    /// named key, or `nil` when the word isn't a chord.
    static func chord(_ word: String) -> String? {
        var word = word.trimmingCharacters(in: CharacterSet(charactersIn: "(),·"))
        guard !word.isEmpty else { return nil }
        // Glyph form: ⌃O, ⇧⇥
        var mods: [String] = []
        while let first = word.first, let mod = modifiers[String(first)] {
            mods.append(mod)
            word.removeFirst()
        }
        let parts = word.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        for part in parts.dropLast() {
            guard let mod = modifiers[part.lowercased()] else { return nil }
            mods.append(mod)
        }
        guard let base = parts.last, !base.isEmpty else { return nil }
        let lower = base.lowercased()
        let key: String
        if let named = namedKeys[lower] {
            key = named
        } else if base == "⇥" {
            key = "tab"
        } else if lower.count == 1, let character = lower.first,
                  character.isLetter || character.isNumber || "?/".contains(character) {
            // A bare letter is a hint only with a modifier or as a lone
            // character after a separator (checked by the caller).
            key = lower
        } else {
            return nil
        }
        if mods.isEmpty, key.count == 1, key != "?", parts.count > 1 { return nil }
        let orderedMods = ["ctrl", "alt", "shift"].filter(mods.contains)
        return (orderedMods + [key]).joined(separator: "+")
    }
}

/// A line split into whitespace-separated words with their terminal cell
/// columns, counting wide characters (CJK, emoji) as two cells.
struct TerminalCellText {
    struct Word {
        var text: String
        var columns: Range<Int>
    }

    let words: [Word]
    private let characters: [(character: Character, column: Int)]

    init(_ line: String) {
        var characters: [(Character, Int)] = []
        var column = 0
        for character in line {
            characters.append((character, column))
            column += Self.cellWidth(character)
        }
        self.characters = characters
        var words: [Word] = []
        var current = ""
        var startColumn = 0
        var endColumn = 0
        for (character, column) in characters {
            if character.isWhitespace {
                if !current.isEmpty {
                    words.append(Word(text: current, columns: startColumn..<endColumn))
                    current = ""
                }
                continue
            }
            if current.isEmpty { startColumn = column }
            current.append(character)
            endColumn = column + Self.cellWidth(character)
        }
        if !current.isEmpty {
            words.append(Word(text: current, columns: startColumn..<endColumn))
        }
        self.words = words
    }

    /// Whether two or more blank cells precede `word` (a column gap in a footer).
    func hasGapBefore(_ word: Word) -> Bool {
        guard let index = words.firstIndex(where: { $0.columns == word.columns }), index > 0 else { return false }
        return word.columns.lowerBound - words[index - 1].columns.upperBound >= 2
    }

    static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
