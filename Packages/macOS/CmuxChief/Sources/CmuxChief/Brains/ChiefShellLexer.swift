import Foundation

/// A deliberately small POSIX shell lexer for ``ChiefToolPolicy``.
///
/// It splits a command line into simple commands (stages) joined by `|`,
/// `&&`, `||`, `;` or a newline, and each stage into words with quotes
/// removed. It understands single and double quotes and backslashes, and
/// drops redirects that cannot write a file: `2>&1`, `>&2`, `2>/dev/null`.
///
/// Anything it does not model returns nil so the caller asks the user:
/// command or process substitution, backticks, subshells, `<` input,
/// heredocs, background `&`, comments, unterminated quotes, redirects to
/// real files, `$'…'` and `$"…"` quoting (ANSI-C escapes and locale
/// translation rewrite the word), and unquoted characters the shell would
/// expand into other words: brace expansion (`{`, `}`), globs (`*`, `?`,
/// `[`, zsh's `^` and `#`), a leading `~` or one after `=` or `:`, and a
/// leading `=` (zsh's `=cmd` path expansion).
struct ChiefShellLexer {
    /// One word of a simple command.
    struct Word: Equatable {
        /// The word with quotes and escapes removed.
        var text: String
        /// Whether the shell would expand a `$` parameter in it.
        var expands: Bool
    }

    /// The simple commands of `line`, or nil when it uses syntax the lexer
    /// does not model.
    static func stages(of line: String) -> [[Word]]? {
        var lexer = ChiefShellLexer(scalars: Array(line.unicodeScalars))
        return lexer.run()
    }

    /// The simple commands of `line`, paired with whether each command is
    /// fed by a preceding pipe. This lets command policy distinguish a
    /// filter reading stdin from a standalone reader that defaults to the
    /// Chief home directory.
    static func stagesWithPipeInput(of line: String) -> [([Word], Bool)]? {
        var lexer = ChiefShellLexer(scalars: Array(line.unicodeScalars))
        guard let stages = lexer.run(), stages.count == lexer.stagePipeInputs.count else { return nil }
        return zip(stages, lexer.stagePipeInputs).map { ($0, $1) }
    }

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var stages: [[Word]] = []
    private var words: [Word] = []
    private var current = ""
    private var started = false
    private var quoted = false
    private var expands = false
    private var stageHasPipeInput = false
    private var stagePipeInputs: [Bool] = []

    private init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    private mutating func finishWord() {
        if started { words.append(Word(text: current, expands: expands)) }
        current = ""
        started = false
        quoted = false
        expands = false
    }

    /// Ends the current stage; an empty one is a syntax the policy rejects.
    private mutating func finishStage() -> Bool {
        finishWord()
        guard !words.isEmpty else { return false }
        stages.append(words)
        stagePipeInputs.append(stageHasPipeInput)
        words = []
        stageHasPipeInput = false
        return true
    }

    private mutating func append(_ scalar: Unicode.Scalar) {
        current.unicodeScalars.append(scalar)
        started = true
    }

    /// A `$` outside single quotes: `$(`, `$'…'` and `$"…"` are rejected,
    /// `$name`, `${…}`, `$1`, `$?` and friends mark the word as expanding, a
    /// lone `$` is literal.
    private mutating func dollar() -> Bool {
        guard let next = peek(1) else { append("$"); return true }
        // `$'--pre=bash'` decodes escapes (`\x74` is `t`), `$"…"` translates.
        if next == "(" || next == "'" || next == "\"" { return false }
        let special: Set<Unicode.Scalar> = ["{", "_", "?", "#", "@", "*", "!", "$", "-"]
        if special.contains(next) || CharacterSet.alphanumerics.contains(next) { expands = true }
        append("$")
        return true
    }

    private mutating func run() -> [[Word]]? {
        var lastSeparatorWasSequence = false
        while let scalar = peek() {
            switch scalar {
            case " ", "\t", "\r":
                finishWord()
                index += 1
                continue
            case "\n", ";":
                guard finishStage() else { return nil }
                lastSeparatorWasSequence = true
                index += 1
                continue
            case "|":
                if peek(1) == "&" { return nil }
                let isPipe = peek(1) != "|"
                guard finishStage() else { return nil }
                stageHasPipeInput = isPipe
                index += peek(1) == "|" ? 2 : 1
                lastSeparatorWasSequence = false
                continue
            case "&":
                guard peek(1) == "&", finishStage() else { return nil }
                index += 2
                lastSeparatorWasSequence = false
                continue
            case ">":
                guard redirect() else { return nil }
            case "<", "`", "(", ")":
                return nil
            case "#" where !started:
                return nil
            case "\\":
                guard let next = peek(1) else { return nil }
                if next == "\n" { index += 2; continue }
                append(next)
                quoted = true
                index += 2
            case "'":
                index += 1
                started = true
                quoted = true
                while let inner = peek(), inner != "'" { append(inner); index += 1 }
                guard peek() == "'" else { return nil }
                index += 1
            case "\"":
                guard doubleQuoted() else { return nil }
            case "$":
                guard dollar() else { return nil }
                index += 1
            case "{", "}", "*", "?", "[", "^", "#":
                // Brace expansion and globs turn one word into others
                // (`clo{s,}e-workspace`, `{--pre=bash,}`).
                return nil
            case "~" where !started || current.unicodeScalars.last == "=" || current.unicodeScalars.last == ":":
                // Tilde expansion: `~`, `--output=~/x`, `PATH:~/bin`.
                return nil
            case "=" where !started:
                // zsh expands `=cmd` to the program's path.
                return nil
            default:
                append(scalar)
                index += 1
            }
            lastSeparatorWasSequence = false
        }
        finishWord()
        if words.isEmpty {
            // `cmux tree;` is fine; a trailing `|` or `&&` is not.
            return lastSeparatorWasSequence && !stages.isEmpty ? stages : nil
        }
        return finishStage() ? stages : nil
    }

    private mutating func doubleQuoted() -> Bool {
        index += 1
        started = true
        quoted = true
        while let scalar = peek() {
            switch scalar {
            case "\"":
                index += 1
                return true
            case "`":
                return false
            case "\\":
                guard let next = peek(1) else { return false }
                if ["$", "`", "\"", "\\"].contains(next) {
                    append(next)
                } else if next != "\n" {
                    append("\\")
                    append(next)
                }
                index += 2
            case "$":
                guard dollar() else { return false }
                index += 1
            default:
                append(scalar)
                index += 1
            }
        }
        return false
    }

    /// `[fd]>[>][&]target` where the target is `/dev/null` or a duplicated
    /// output descriptor (`&1`, `&2`). The redirect is dropped from the words.
    private mutating func redirect() -> Bool {
        // A bare number right before `>` is the descriptor (`2>&1`); any
        // other text before it is a word of its own (`ls>x`).
        if started, !quoted, !current.isEmpty, current.allSatisfy({ $0.isASCII && $0.isNumber }) {
            current = ""
            started = false
            expands = false
        } else {
            finishWord()
        }
        index += 1
        if peek() == ">" { index += 1 } else if peek() == "|" { return false }
        var duplicate = false
        if peek() == "&" { duplicate = true; index += 1 }
        while peek() == " " || peek() == "\t" { index += 1 }
        var target = ""
        while let scalar = peek(), !" \t\r\n;|&<>()`'\"$\\".unicodeScalars.contains(scalar) {
            target.unicodeScalars.append(scalar)
            index += 1
        }
        return duplicate ? (target == "1" || target == "2") : target == "/dev/null"
    }
}
