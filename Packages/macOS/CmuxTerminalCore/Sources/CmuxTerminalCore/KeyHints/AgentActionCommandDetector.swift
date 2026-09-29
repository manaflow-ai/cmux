public import Foundation

/// A safe, explicitly allowlisted action command printed by an agent.
/// Commands are returned with their terminal-cell range so the caller can
/// make only the command itself clickable.
public struct AgentActionCommand: Sendable, Equatable {
    public let command: String
    public let columns: Range<Int>

    public init(command: String, columns: Range<Int>) {
        self.command = command
        self.columns = columns
    }
}

/// Finds action commands that are safe to send verbatim to a Codex session.
/// Keep this list deliberately small: clicking arbitrary shell text would be
/// surprising and could execute destructive commands.
public struct CodexActionCommandDetector: Sendable {
    public init() {}

    public func command(in line: String, atColumn column: Int) -> AgentActionCommand? {
        commands(in: line).first { $0.columns.contains(column) }
    }

    public func commands(in line: String) -> [AgentActionCommand] {
        let cells = ActionCommandCellText(line)
        var result: [AgentActionCommand] = []
        for index in cells.words.indices {
            guard index + 1 < cells.words.count else { continue }
            let first = cells.words[index]
            let second = cells.words[index + 1]
            let phrase = "\(first.text) \(second.text)".lowercased()
            guard Self.allowlist.contains(phrase) else { continue }
            // Require the whole rendered row to be the command (with optional
            // terminal padding). This prevents prose or shell examples from
            // becoming executable click targets.
            guard line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == phrase else { continue }
            result.append(AgentActionCommand(command: phrase, columns: first.columns.lowerBound..<second.columns.upperBound))
        }
        return result
    }

    private static let allowlist: Set<String> = ["/goal resume"]
}

private struct ActionCommandCellText {
    struct Word {
        let text: String
        let columns: Range<Int>
    }

    let words: [Word]

    init(_ line: String) {
        var words: [Word] = []
        var current = ""
        var start = 0
        var end = 0
        var column = 0
        for character in line {
            if character.isWhitespace {
                if !current.isEmpty {
                    words.append(Word(text: current, columns: start..<end))
                    current = ""
                }
            } else {
                if current.isEmpty { start = column }
                current.append(character)
                end = column + 1
            }
            column += 1
        }
        if !current.isEmpty { words.append(Word(text: current, columns: start..<end)) }
        self.words = words
    }
}
