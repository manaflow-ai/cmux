import Foundation

/// A preferred-editor command with shell-aware executable recognition.
///
/// Source locations are emitted only for simple editor CLI commands whose
/// argument contract is known. Unknown or compound shell commands receive the
/// plain file path so cmux never guesses where location arguments would bind.
nonisolated struct PreferredEditorLaunchCommand: Equatable, Sendable {
    let command: String

    init(command: String) {
        self.command = command
    }

    var supportsSourceLocation: Bool {
        guard let executableName else { return false }
        return [
            "code", "code-insiders", "codium", "cursor", "subl", "zed", "zed-preview",
        ].contains(executableName)
    }

    func shellCommand(url: URL, line: Int?, column: Int?) -> String {
        let path = url.path
        let arguments: [String]
        if let line, supportsSourceLocation {
            let location = column.map { "\(path):\(line):\($0)" } ?? "\(path):\(line)"
            if usesGotoFlag {
                arguments = hasGotoFlag ? [location] : ["--goto", location]
            } else {
                arguments = [location]
            }
        } else {
            arguments = [path]
        }

        return ([command] + arguments.map(\.posixShellSingleQuoted))
            .joined(separator: " ")
    }

    private var usesGotoFlag: Bool {
        guard let executableName else { return false }
        return ["code", "code-insiders", "codium", "cursor"].contains(executableName)
    }

    private var hasGotoFlag: Bool {
        shellWords?.contains { token in
            token == "-g" || token == "--goto"
        } ?? false
    }

    private var executableName: String? {
        guard let words = shellWords, !words.contains("--") else { return nil }
        var index = 0
        while index < words.count, isEnvironmentAssignment(words[index]) {
            index += 1
        }
        guard index < words.count else { return nil }

        if (words[index] as NSString).lastPathComponent.lowercased() == "env" {
            index += 1
            while index < words.count {
                let word = words[index]
                if word == "-u" || word == "--unset" {
                    index += 2
                } else if word.hasPrefix("--unset=") ||
                            word.hasPrefix("-") ||
                            isEnvironmentAssignment(word) {
                    index += 1
                } else {
                    break
                }
            }
        }

        guard index < words.count else { return nil }
        return (words[index] as NSString).lastPathComponent.lowercased()
    }

    private var shellWords: [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\", quote != "'" {
                escaping = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "$" || character == "`" {
                    return nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isNewline || "$`#;|&<>()".contains(character) {
                return nil
            } else if character.isWhitespace {
                finishWord()
            } else {
                current.append(character)
            }
        }

        guard quote == nil, !escaping else { return nil }
        finishWord()
        return words
    }

    private func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
        }
    }
}
