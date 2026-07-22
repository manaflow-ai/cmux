import Foundation

/// Identifies shell redirection targets without guessing command-specific flag semantics.
struct ShellArtifactMutationPathDetector: Sendable {
    private enum Token: Equatable {
        case word(String)
        case redirect
        case boundary
    }

    func paths(in command: String) -> [String] {
        let tokens = tokenize(command)
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
            case .redirect:
                append(nextWord(after: index, in: tokens))
            case .word, .boundary:
                break
            }
        }

        return paths
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
            if character.isWhitespace {
                flushWord()
                if character == "\n" { tokens.append(.boundary) }
                index += 1
                continue
            }
            if character == ">" {
                flushWord()
                tokens.append(.redirect)
                index += characters[safe: index + 1] == ">" ? 2 : 1
                continue
            }
            if character == "&", characters[safe: index + 1] == ">" {
                flushWord()
                tokens.append(.redirect)
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
            case .redirect: continue
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
