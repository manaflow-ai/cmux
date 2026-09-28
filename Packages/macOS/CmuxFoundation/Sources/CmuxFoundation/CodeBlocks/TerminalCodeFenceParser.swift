import Foundation

/// One fenced code block found in a run of lines.
public struct TerminalCodeFence: Sendable, Equatable {
    /// The fence info string (`bash title="x"`), or `nil` when bare.
    public let infoString: String?

    /// The lines between the fences, with the opening fence's indentation
    /// removed. Unmodified otherwise: see ``TerminalCodeBlockText`` for the
    /// copy form.
    public let body: [String]

    /// Index of the opening fence line.
    public let openingLine: Int

    /// Index of the closing fence line, or `nil` when the fence was never
    /// closed (the block ran to the end of the input).
    public let closingLine: Int?
}

/// Finds fenced code blocks (```` ``` ```` or `~~~`) in markdown text or in
/// rows read off a terminal screen.
///
/// Follows CommonMark's fence rules (a closing fence uses the same character,
/// at least as long as the opening one, with nothing after it) but accepts
/// any indentation, because agents indent fences inside list items and TUIs
/// add a left margin.
public struct TerminalCodeFenceParser: Sendable {
    public init() {}

    /// Fences in a markdown string.
    public func fences(inMarkdown markdown: String) -> [TerminalCodeFence] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return fences(inLines: lines)
    }

    /// Fences in an array of lines. An unclosed fence is reported only when
    /// `includeUnclosed` is set: a screen read can cut a block in half, and a
    /// half block must not be offered as the whole command.
    public func fences(inLines lines: [String], includeUnclosed: Bool = true) -> [TerminalCodeFence] {
        var result: [TerminalCodeFence] = []
        var index = 0
        while index < lines.count {
            guard let opening = Self.openingFence(lines[index]) else {
                index += 1
                continue
            }
            var body: [String] = []
            var closing: Int?
            var cursor = index + 1
            while cursor < lines.count {
                if Self.isClosingFence(lines[cursor], matching: opening) {
                    closing = cursor
                    break
                }
                body.append(Self.removingIndent(opening.indent, from: lines[cursor]))
                cursor += 1
            }
            if closing != nil || includeUnclosed {
                result.append(
                    TerminalCodeFence(
                        infoString: opening.info.isEmpty ? nil : opening.info,
                        body: body,
                        openingLine: index,
                        closingLine: closing
                    )
                )
            }
            index = (closing ?? cursor) + 1
        }
        return result
    }

    private struct Opening {
        let character: Character
        let length: Int
        let indent: Int
        let info: String
    }

    private static func openingFence(_ line: String) -> Opening? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let rest = line.dropFirst(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // CommonMark: a backtick fence's info string cannot contain a backtick
        // (that line is inline code, not a fence).
        if character == "`", info.contains("`") { return nil }
        return Opening(character: character, length: length, indent: indent, info: info)
    }

    private static func isClosingFence(_ line: String, matching opening: Opening) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= opening.length else { return false }
        return trimmed.allSatisfy { $0 == opening.character }
    }

    private static func removingIndent(_ indent: Int, from line: String) -> String {
        guard indent > 0 else { return line }
        let removable = line.prefix(indent).prefix(while: { $0 == " " || $0 == "\t" }).count
        return String(line.dropFirst(removable))
    }
}

/// Turns fence bodies or screen rows into the text Copy should produce.
public struct TerminalCodeBlockText: Sendable {
    /// Leading prompt glyphs agents and docs put in front of commands.
    static let promptPrefixes = ["$ ", "% ", "❯ ", "➜ ", "λ "]

    public init() {}

    /// The copy text for a fence body.
    ///
    /// - Trailing spaces go and leading/trailing blank lines are dropped.
    /// - Common indentation is removed (TUI margins, list nesting).
    /// - A session block (`console`) keeps only its prompted command lines
    ///   and their `> ` continuations, without the prompts; output is dropped.
    /// - A shell block whose every line starts with `$ ` loses the prompts.
    public func copyText(body: [String], language: TerminalCodeBlockLanguage) -> String {
        var lines = body.map { Self.trimmingTrailingWhitespace($0) }
        lines = Self.dedented(lines)
        if language.isSession, let commands = Self.sessionCommands(lines) {
            lines = commands
        } else if language.isShell || language.name == nil,
                  let stripped = Self.strippingUniformPrompt(lines) {
            lines = stripped
        }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The copy text for a whole fence.
    public func copyText(for fence: TerminalCodeFence) -> String {
        copyText(body: fence.body, language: TerminalCodeBlockLanguage(infoString: fence.infoString))
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" || line[previous] == "\u{00A0}" else { break }
            end = previous
        }
        return String(line[..<end])
    }

    private static func dedented(_ lines: [String]) -> [String] {
        let indents = lines
            .filter { !$0.isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }
        guard let common = indents.min(), common > 0 else { return lines }
        return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(common)) }
    }

    private static func promptPrefix(of line: String) -> String? {
        promptPrefixes.first { line.hasPrefix($0) }
    }

    private static func strippingUniformPrompt(_ lines: [String]) -> [String]? {
        let nonEmpty = lines.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty, nonEmpty.allSatisfy({ promptPrefix(of: $0) != nil }) else { return nil }
        return lines.map { line in
            guard let prefix = promptPrefix(of: line) else { return line }
            return String(line.dropFirst(prefix.count))
        }
    }

    private static func sessionCommands(_ lines: [String]) -> [String]? {
        var commands: [String] = []
        var previousWasCommand = false
        for line in lines {
            if let prefix = promptPrefix(of: line) {
                commands.append(String(line.dropFirst(prefix.count)))
                previousWasCommand = true
            } else if previousWasCommand, line.hasPrefix("> ") {
                commands.append(String(line.dropFirst(2)))
            } else {
                previousWasCommand = false
            }
        }
        return commands.isEmpty ? nil : commands
    }
}
