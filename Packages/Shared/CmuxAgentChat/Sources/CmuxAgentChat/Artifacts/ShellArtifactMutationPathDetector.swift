import Foundation

/// Identifies shell redirection targets without guessing command-specific flag semantics.
struct ShellArtifactMutationPathDetector: Sendable {
    private enum Token: Equatable {
        case word(String)
        case outputRedirect
        case readWriteRedirect
        case boundary
    }

    func paths(in command: String) -> [String] {
        let tokens = tokenize(command)
        return paths(in: tokens)
    }

    /// Returns mutation targets only when one successful status attributes execution directly.
    func pathsAttributedToSuccessfulCommand(in command: String) -> [String] {
        let tokens = tokenize(command)
        guard !tokens.contains(where: { token in
            if case .boundary = token { return true }
            return false
        }), !containsCompoundGrouping(command) else {
            return []
        }
        return paths(in: tokens)
    }

    private func paths(in tokens: [Token]) -> [String] {
        var paths: [String] = []
        var seen: Set<String> = []

        func append(_ raw: String?) {
            guard let raw, let path = normalizedPath(raw), seen.insert(path).inserted else {
                return
            }
            paths.append(path)
        }

        for index in tokens.indices {
            switch tokens[index] {
            case .outputRedirect:
                append(nextWord(after: index, in: tokens))
            case .word, .readWriteRedirect, .boundary:
                break
            }
        }

        return paths
    }

    private func containsCompoundGrouping(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "[", characters[safe: index + 1] == "[" {
                return true
            } else if "(){}".contains(character) {
                return true
            }
            index += 1
        }
        return false
    }

    private func tokenize(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var quote: Character?
        var escaped = false
        let characters = Array(command)
        var index = 0

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(.word(word))
            word = ""
        }

        while index < characters.count {
            let character = characters[index]
            if escaped {
                word.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    word.append(character)
                }
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                index += 1
                continue
            }
            if character == "#", word.isEmpty {
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                if index < characters.count {
                    if tokens.last != .boundary { tokens.append(.boundary) }
                    index += 1
                }
                continue
            }
            if character.isWhitespace {
                flushWord()
                if character == "\n" { tokens.append(.boundary) }
                index += 1
                continue
            }
            if character == "<", characters[safe: index + 1] == ">" {
                flushWord()
                tokens.append(.readWriteRedirect)
                index += 2
                continue
            }
            if character == ">" {
                flushWord()
                tokens.append(.outputRedirect)
                index += characters[safe: index + 1] == ">" ? 2 : 1
                continue
            }
            if character == "&", characters[safe: index + 1] == ">" {
                flushWord()
                tokens.append(.outputRedirect)
                index += 2
                continue
            }
            if character == ";" || character == "|" || character == "&" {
                flushWord()
                if tokens.last != .boundary { tokens.append(.boundary) }
                index += characters[safe: index + 1] == character ? 2 : 1
                continue
            }
            word.append(character)
            index += 1
        }
        if escaped { word.append("\\") }
        flushWord()
        return tokens
    }

    private func nextWord(after index: Int, in tokens: [Token]) -> String? {
        guard index + 1 < tokens.count else { return nil }
        for token in tokens[(index + 1)...] {
            switch token {
            case .word(let word): return word
            case .outputRedirect: continue
            case .readWriteRedirect: return nil
            case .boundary: return nil
            }
        }
        return nil
    }

    private func normalizedPath(_ raw: String) -> String? {
        let path: String
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
            path = url.path
        } else {
            path = raw
        }
        guard !path.isEmpty,
              path != "-",
              path != "/dev/null",
              !path.contains("\n"),
              !path.contains("\0"),
              !path.contains("$"),
              path.hasPrefix("/")
                || path.hasPrefix("./")
                || path.hasPrefix("../")
                || path.hasPrefix("~/")
                || path.contains("/")
                || !URL(fileURLWithPath: path).pathExtension.isEmpty else {
            return nil
        }
        return path
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
