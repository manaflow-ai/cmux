import Foundation

/// Composes shell-safe task startup parameters from templates and user prompts.
public struct MobileTaskCommandComposer: Sendable {
    private enum ShellQuote {
        case unquoted
        case single
        case double
    }

    private struct ShellLexicalState {
        private(set) var quote = ShellQuote.unquoted
        private(set) var escaped = false
        private(set) var inComment = false
        private var atWordBoundary = true

        var permitsEnvironmentExpansion: Bool {
            !inComment && !escaped && quote != .single
        }

        func startsComment(with character: Character) -> Bool {
            quote == .unquoted && !escaped && character == "#" && atWordBoundary
        }

        mutating func beginComment() {
            inComment = true
        }

        mutating func markExpansion() {
            atWordBoundary = false
        }

        mutating func consume(_ character: Character) {
            if inComment {
                if character == "\n" {
                    inComment = false
                    atWordBoundary = true
                }
                return
            }
            if escaped {
                escaped = false
                atWordBoundary = false
                return
            }
            switch (quote, character) {
            case (.unquoted, "\\"), (.double, "\\"):
                escaped = true
            case (.unquoted, "'"):
                quote = .single
                atWordBoundary = false
            case (.unquoted, "\""):
                quote = .double
                atWordBoundary = false
            case (.single, "'"):
                quote = .unquoted
            case (.double, "\""):
                quote = .unquoted
            case (.unquoted, " "), (.unquoted, "\t"), (.unquoted, "\r"), (.unquoted, "\n"):
                atWordBoundary = true
            case (.unquoted, ";"), (.unquoted, "|"), (.unquoted, "&"),
                 (.unquoted, "("), (.unquoted, ")"), (.unquoted, "<"), (.unquoted, ">"):
                atWordBoundary = true
            default:
                if quote == .unquoted {
                    atWordBoundary = false
                }
            }
        }
    }

    private struct ShellWord {
        var end: String.Index?
        var unquotedText: String? = ""
        var assignmentName = ""
        var isAssignment = false
        var canBeAssignment = true
        var isUnquotedDigits = true

        mutating func consume(_ character: Character, isUnquotedLiteral: Bool, end: String.Index) {
            self.end = end
            guard isUnquotedLiteral else {
                unquotedText = nil
                canBeAssignment = false
                isUnquotedDigits = false
                return
            }
            unquotedText?.append(character)
            guard canBeAssignment else {
                isUnquotedDigits = isUnquotedDigits && character.isNumber
                return
            }
            if character == "=" {
                isAssignment = MobileTaskCommandComposer.isShellAssignmentName(assignmentName)
                canBeAssignment = false
                isUnquotedDigits = false
            } else {
                assignmentName.append(character)
                isUnquotedDigits = isUnquotedDigits && character.isNumber
            }
        }
    }

    private struct ShellCommandScan {
        var containsCommand = false
        var promptInsertionIndex: String.Index?
        var supportsImplicitPrompt = true
    }

    private struct ShellHereDocumentDescriptor {
        var delimiter: String
        var stripsLeadingTabs: Bool
        var permitsEnvironmentExpansion: Bool
    }

    private struct ShellHereDocumentBody {
        var range: Range<String.Index>
        var permitsEnvironmentExpansion: Bool
    }

    /// Creates a command composer.
    public init() {}

    static func containsExecutableCommand(in command: String) -> Bool {
        scanShellCommand(command).containsCommand
    }

    /// Composes workspace-create parameters for `template` and `prompt`.
    /// - Parameters:
    ///   - template: The selected task template.
    ///   - prompt: User-entered task prompt.
    /// - Returns: The derived command, environment, and title.
    public func compose(template: MobileTaskTemplate, prompt rawPrompt: String) -> MobileTaskComposition {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = template.command
        let title = Self.taskTitle(from: prompt)

        guard !template.isPlainShell else {
            return MobileTaskComposition(initialCommand: nil, initialEnv: [:], title: title)
        }

        let interpolation = Self.interpolatingPromptEnvironment(in: command)
        let explicitlyReferencesPrompt = Self.referencesPromptEnvironment(in: command)
        let initialCommand: String
        let usesPromptEnvironment: Bool
        if interpolation.didReplacePrompt {
            initialCommand = interpolation.command
            usesPromptEnvironment = true
        } else if explicitlyReferencesPrompt {
            initialCommand = command
            usesPromptEnvironment = true
        } else if !prompt.isEmpty {
            if let appendedCommand = Self.appendingPromptArgument(to: command) {
                initialCommand = appendedCommand
                usesPromptEnvironment = true
            } else {
                initialCommand = command
                usesPromptEnvironment = false
            }
        } else {
            initialCommand = command
            usesPromptEnvironment = false
        }

        let env = usesPromptEnvironment
            ? ["CMUX_TASK_PROMPT": prompt]
            : [:]
        return MobileTaskComposition(initialCommand: initialCommand, initialEnv: env, title: title)
    }

    /// Replaces unescaped `{prompt}` placeholders with an environment expansion
    /// that is safe in the placeholder's current POSIX shell quote context.
    private static func interpolatingPromptEnvironment(in command: String) -> (command: String, didReplacePrompt: Bool) {
        var output = ""
        var index = command.startIndex
        var lexicalState = ShellLexicalState()
        var didReplacePrompt = false
        let hereDocumentBodies = hereDocumentBodies(in: command)
        var hereDocumentBodyIndex = 0

        while index < command.endIndex {
            if hereDocumentBodyIndex < hereDocumentBodies.count,
               index == hereDocumentBodies[hereDocumentBodyIndex].range.lowerBound {
                let body = hereDocumentBodies[hereDocumentBodyIndex]
                output.append(contentsOf: command[body.range])
                if command[body.range].last == "\n" {
                    lexicalState.consume("\n")
                }
                index = body.range.upperBound
                hereDocumentBodyIndex += 1
                continue
            }
            let character = command[index]
            if lexicalState.inComment {
                output.append(character)
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }

            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                output.append(character)
                index = command.index(after: index)
                continue
            }

            if !lexicalState.escaped, command[index...].hasPrefix("{prompt}") {
                switch lexicalState.quote {
                case .unquoted:
                    output += "\"${CMUX_TASK_PROMPT}\""
                case .single:
                    output += "'\"${CMUX_TASK_PROMPT}\"'"
                case .double:
                    output += "${CMUX_TASK_PROMPT}"
                }
                index = command.index(index, offsetBy: "{prompt}".count)
                didReplacePrompt = true
                lexicalState.markExpansion()
                continue
            }

            output.append(character)
            lexicalState.consume(character)
            index = command.index(after: index)
        }
        return (output, didReplacePrompt)
    }

    /// Inserts the fallback prompt argument after the final executable token,
    /// preserving any trailing shell whitespace and comments byte-for-byte.
    private static func appendingPromptArgument(to command: String) -> String? {
        let scan = scanShellCommand(command)
        guard scan.supportsImplicitPrompt, let insertionIndex = scan.promptInsertionIndex else { return nil }
        return String(command[..<insertionIndex])
            + " -- \"${CMUX_TASK_PROMPT}\""
            + String(command[insertionIndex...])
    }

    /// Finds executable words without trying to interpret the full shell grammar.
    /// Leading assignments and redirection operands are not commands; unquoted
    /// control operators start a new simple command.
    private static func scanShellCommand(_ command: String) -> ShellCommandScan {
        var lexicalState = ShellLexicalState()
        var word = ShellWord()
        var commandInSegment = false
        var expectsRedirectionOperand = false
        var result = ShellCommandScan()

        func finishWord(asFileDescriptor: Bool = false) {
            guard let wordEnd = word.end else { return }
            defer { word = ShellWord() }
            if asFileDescriptor && word.isUnquotedDigits { return }
            if expectsRedirectionOperand {
                expectsRedirectionOperand = false
                if commandInSegment { result.promptInsertionIndex = wordEnd }
                return
            }
            if !commandInSegment && word.isAssignment { return }
            if !commandInSegment,
               let unquotedText = word.unquotedText,
               unsupportedCommandWords.contains(unquotedText) {
                result.supportsImplicitPrompt = false
            }
            if !commandInSegment, result.containsCommand {
                result.supportsImplicitPrompt = false
            }
            commandInSegment = true
            result.containsCommand = true
            result.promptInsertionIndex = wordEnd
        }

        func resetSegment() {
            commandInSegment = false
            expectsRedirectionOperand = false
        }

        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)
            if lexicalState.inComment {
                if character == "\n" { resetSegment() }
                lexicalState.consume(character)
                index = nextIndex
                continue
            }
            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                index = nextIndex
                continue
            }

            if lexicalState.quote == .unquoted, !lexicalState.escaped {
                switch character {
                case " ", "\t", "\r":
                    finishWord()
                case "\n":
                    finishWord()
                    resetSegment()
                case ";", "|", "&":
                    finishWord()
                    resetSegment()
                case "(", ")", "{", "}":
                    finishWord()
                    result.supportsImplicitPrompt = false
                    resetSegment()
                case "<", ">":
                    if character == "<", command[index...].hasPrefix("<<") {
                        result.supportsImplicitPrompt = false
                    }
                    finishWord(asFileDescriptor: word.end == index)
                    expectsRedirectionOperand = true
                default:
                    word.consume(character, isUnquotedLiteral: true, end: nextIndex)
                }
            } else {
                word.consume(character, isUnquotedLiteral: false, end: nextIndex)
            }
            lexicalState.consume(character)
            index = nextIndex
        }
        finishWord()
        return result
    }

    /// The documented environment-variable form is an explicit prompt consumer,
    /// so the composer must not append a second prompt argument.
    private static func referencesPromptEnvironment(in command: String) -> Bool {
        let unbraced = "$CMUX_TASK_PROMPT"
        let bracedPrefix = "${CMUX_TASK_PROMPT"
        let bracedLengthExpansion = "${#CMUX_TASK_PROMPT}"
        var lexicalState = ShellLexicalState()
        var index = command.startIndex
        let hereDocumentBodies = hereDocumentBodies(in: command)
        var hereDocumentBodyIndex = 0
        while index < command.endIndex {
            if hereDocumentBodyIndex < hereDocumentBodies.count,
               index == hereDocumentBodies[hereDocumentBodyIndex].range.lowerBound {
                let body = hereDocumentBodies[hereDocumentBodyIndex]
                if body.permitsEnvironmentExpansion,
                   hereDocumentBodyReferencesPromptEnvironment(command[body.range]) {
                    return true
                }
                if command[body.range].last == "\n" {
                    lexicalState.consume("\n")
                }
                index = body.range.upperBound
                hereDocumentBodyIndex += 1
                continue
            }
            let character = command[index]
            if lexicalState.inComment {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }
            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                index = command.index(after: index)
                continue
            }
            if lexicalState.permitsEnvironmentExpansion {
                if command[index...].hasPrefix(bracedLengthExpansion) {
                    return true
                }
                if command[index...].hasPrefix(bracedPrefix) {
                    let nameEnd = command.index(index, offsetBy: bracedPrefix.count)
                    if nameEnd < command.endIndex,
                       !Self.isShellIdentifierCharacter(command[nameEnd]) {
                        return true
                    }
                }
                if command[index...].hasPrefix(unbraced) {
                    let end = command.index(index, offsetBy: unbraced.count)
                    if end == command.endIndex || !Self.isShellIdentifierCharacter(command[end]) {
                        return true
                    }
                }
            }
            lexicalState.consume(character)
            index = command.index(after: index)
        }
        return false
    }

    /// Returns shell here-document body and terminator lines. Those lines are
    /// data, not shell syntax, so `{prompt}` must remain byte-for-byte literal.
    private static func hereDocumentBodies(in command: String) -> [ShellHereDocumentBody] {
        var bodies: [ShellHereDocumentBody] = []
        var pending: [ShellHereDocumentDescriptor] = []
        var lexicalState = ShellLexicalState()
        var readingBodies = false
        var lineStart = command.startIndex

        while lineStart < command.endIndex {
            let newline = command[lineStart...].firstIndex(of: "\n")
            let contentEnd = newline ?? command.endIndex
            let lineEnd = newline.map { command.index(after: $0) } ?? command.endIndex

            if readingBodies, let descriptor = pending.first {
                var candidate = String(command[lineStart..<contentEnd])
                if candidate.last == "\r" { candidate.removeLast() }
                if descriptor.stripsLeadingTabs {
                    candidate.removeFirst(candidate.prefix(while: { $0 == "\t" }).count)
                }
                let isTerminator = candidate == descriptor.delimiter
                bodies.append(ShellHereDocumentBody(
                    range: lineStart..<lineEnd,
                    permitsEnvironmentExpansion: descriptor.permitsEnvironmentExpansion && !isTerminator
                ))
                if isTerminator {
                    pending.removeFirst()
                    readingBodies = !pending.isEmpty
                }
            } else {
                scanHereDocumentDescriptors(
                    in: command,
                    range: lineStart..<contentEnd,
                    lexicalState: &lexicalState,
                    pending: &pending
                )
                readingBodies = !pending.isEmpty
                    && !lexicalState.escaped
                    && lexicalState.quote == .unquoted
            }

            if newline != nil { lexicalState.consume("\n") }
            lineStart = lineEnd
        }
        return bodies
    }

    private static func scanHereDocumentDescriptors(
        in command: String,
        range: Range<String.Index>,
        lexicalState: inout ShellLexicalState,
        pending: inout [ShellHereDocumentDescriptor]
    ) {
        var index = range.lowerBound
        while index < range.upperBound {
            let character = command[index]
            if lexicalState.inComment {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }
            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                index = command.index(after: index)
                continue
            }
            guard lexicalState.quote == .unquoted, !lexicalState.escaped, character == "<" else {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }

            let suffix = command[index..<range.upperBound]
            if suffix.hasPrefix("<<<") {
                for _ in 0..<3 {
                    lexicalState.consume(command[index])
                    index = command.index(after: index)
                }
                continue
            }
            guard suffix.hasPrefix("<<") else {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }

            var cursor = command.index(index, offsetBy: 2)
            var stripsLeadingTabs = false
            if cursor < range.upperBound, command[cursor] == "-" {
                stripsLeadingTabs = true
                cursor = command.index(after: cursor)
            }
            while cursor < range.upperBound, command[cursor] == " " || command[cursor] == "\t" {
                cursor = command.index(after: cursor)
            }
            guard let parsed = parseHereDocumentDelimiter(
                in: command,
                from: cursor,
                through: range.upperBound
            ) else {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }
            pending.append(ShellHereDocumentDescriptor(
                delimiter: parsed.delimiter,
                stripsLeadingTabs: stripsLeadingTabs,
                permitsEnvironmentExpansion: !parsed.wasQuoted
            ))
            while index < parsed.end {
                lexicalState.consume(command[index])
                index = command.index(after: index)
            }
        }
    }

    private static func parseHereDocumentDelimiter(
        in command: String,
        from start: String.Index,
        through end: String.Index
    ) -> (delimiter: String, wasQuoted: Bool, end: String.Index)? {
        var delimiter = ""
        var quote = ShellQuote.unquoted
        var wasQuoted = false
        var index = start
        while index < end {
            let character = command[index]
            if quote == .unquoted,
               character == " " || character == "\t" || ";|&<>()".contains(character) {
                break
            }
            switch (quote, character) {
            case (.unquoted, "'"), (.unquoted, "\""):
                wasQuoted = true
                quote = character == "'" ? .single : .double
            case (.single, "'"):
                quote = .unquoted
            case (.double, "\""):
                quote = .unquoted
            case (.unquoted, "\\"), (.double, "\\"):
                wasQuoted = true
                let escaped = command.index(after: index)
                guard escaped < end else {
                    index = escaped
                    continue
                }
                delimiter.append(command[escaped])
                index = escaped
            default:
                delimiter.append(character)
            }
            index = command.index(after: index)
        }
        guard !delimiter.isEmpty else { return nil }
        return (delimiter, wasQuoted, index)
    }

    private static func hereDocumentBodyReferencesPromptEnvironment(_ body: Substring) -> Bool {
        let unbraced = "$CMUX_TASK_PROMPT"
        let bracedPrefix = "${CMUX_TASK_PROMPT"
        let bracedLengthExpansion = "${#CMUX_TASK_PROMPT}"
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "\\" {
                index = body.index(after: index)
                if index < body.endIndex { index = body.index(after: index) }
                continue
            }
            if body[index...].hasPrefix(bracedLengthExpansion) {
                return true
            }
            if body[index...].hasPrefix(bracedPrefix) {
                let nameEnd = body.index(index, offsetBy: bracedPrefix.count)
                if nameEnd < body.endIndex, !isShellIdentifierCharacter(body[nameEnd]) {
                    return true
                }
            }
            if body[index...].hasPrefix(unbraced) {
                let nameEnd = body.index(index, offsetBy: unbraced.count)
                if nameEnd == body.endIndex || !isShellIdentifierCharacter(body[nameEnd]) {
                    return true
                }
            }
            index = body.index(after: index)
        }
        return false
    }

    private static func isShellIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private static func isShellAssignmentName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy(isShellIdentifierCharacter)
    }

    private static let unsupportedCommandWords: Set<String> = [
        "if", "then", "elif", "else", "fi",
        "for", "while", "until", "do", "done",
        "case", "esac",
    ]

    /// The suggested workspace title for a task prompt: its first line, capped
    /// at 60 characters. Static (not file-scope): the package conventions lint
    /// forbids free functions in iOS package sources.
    private static func taskTitle(from prompt: String) -> String? {
        guard let firstLine = prompt.split(separator: "\n", omittingEmptySubsequences: false).first,
              !firstLine.isEmpty else {
            return nil
        }
        return String(firstLine.prefix(60))
    }
}
