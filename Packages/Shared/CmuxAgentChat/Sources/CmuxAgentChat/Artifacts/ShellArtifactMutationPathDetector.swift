import Foundation

/// Identifies explicit output targets in shell commands without treating inputs as writes.
struct ShellArtifactMutationPathDetector: Sendable {
    private enum Token: Equatable {
        case word(String)
        case redirect
        case boundary
    }

    private static let outputFlags: Set<String> = [
        "-o", "--out", "--outfile", "--output", "--output-file",
        "--save", "--save-to", "--dest", "--destination", "--export",
    ]
    private static let allDestinationCommands: Set<String> = ["tee", "touch"]
    private static let lastDestinationCommands: Set<String> = [
        "convert", "cp", "ffmpeg", "install", "magick", "mv", "screencapture",
    ]
    private static let commandWrappers: Set<String> = [
        "command", "env", "nice", "nohup", "sudo", "time", "xcrun",
    ]

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
            case .word(let word):
                if Self.outputFlags.contains(word) {
                    append(nextWord(after: index, in: tokens))
                } else if let separator = word.firstIndex(of: "=") {
                    let flag = String(word[..<separator])
                    if Self.outputFlags.contains(flag) {
                        append(String(word[word.index(after: separator)...]))
                    }
                }
            case .boundary:
                break
            }
        }

        for segment in segments(tokens) {
            let words = segment.compactMap { token -> String? in
                guard case .word(let word) = token else { return nil }
                return word
            }
            guard let commandIndex = commandIndex(in: words) else { continue }
            let executable = URL(fileURLWithPath: words[commandIndex]).lastPathComponent.lowercased()
            let arguments = Array(words.dropFirst(commandIndex + 1))
            if Self.allDestinationCommands.contains(executable) {
                for argument in positionalArguments(arguments) {
                    append(argument)
                }
            } else if Self.lastDestinationCommands.contains(executable) {
                append(positionalArguments(arguments).last)
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

    private func segments(_ tokens: [Token]) -> [[Token]] {
        var result: [[Token]] = [[]]
        for token in tokens {
            if token == .boundary {
                if result.last?.isEmpty == false { result.append([]) }
            } else {
                result[result.count - 1].append(token)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    private func commandIndex(in words: [String]) -> Int? {
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.contains("="), !word.hasPrefix("-") {
                index += 1
                continue
            }
            let executable = URL(fileURLWithPath: word).lastPathComponent.lowercased()
            if Self.commandWrappers.contains(executable) {
                index += 1
                while index < words.count, words[index].hasPrefix("-") { index += 1 }
                continue
            }
            return index
        }
        return nil
    }

    private func positionalArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var skipsOutputValue = false
        for argument in arguments {
            if skipsOutputValue {
                skipsOutputValue = false
                continue
            }
            if Self.outputFlags.contains(argument) {
                skipsOutputValue = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            result.append(argument)
        }
        return result
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
