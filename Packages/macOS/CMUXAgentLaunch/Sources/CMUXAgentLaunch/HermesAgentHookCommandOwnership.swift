import Foundation

/// Recognizes lifecycle and feed hook commands that cmux owns in Hermes' consent allowlist.
struct HermesAgentHookCommandOwnership {
    private enum Quote: Equatable {
        case none
        case single
        case double
    }

    private let pinnedMarker = "cmux-hermes-agent-hook-v2"

    func containsOwnedCommand(_ command: String) -> Bool {
        let body = shellBody(from: command)
        if body.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(": \(pinnedMarker);") {
            return true
        }
        return shellSegments(in: body).contains(where: isLegacyCmuxInvocation)
    }

    private func shellBody(from command: String) -> String {
        let outerSegments = shellSegments(in: command)
        guard outerSegments.count == 1,
              let words = outerSegments.first,
              words.count >= 3,
              URL(fileURLWithPath: words[0]).lastPathComponent == "sh",
              words[1] == "-c" else {
            return command
        }
        return words[2]
    }

    private func isLegacyCmuxInvocation(_ segment: [String]) -> Bool {
        var words = segment
        while let first = words.first, ["then", "else", "do"].contains(first) {
            words.removeFirst()
        }
        while let first = words.first, isEnvironmentAssignment(first) {
            words.removeFirst()
        }
        guard let executable = words.first, isCmuxExecutable(executable) else {
            return false
        }

        var index = 1
        if index < words.count, words[index] == "--socket" {
            guard index + 1 < words.count else { return false }
            index += 2
        } else if index < words.count, words[index].hasPrefix("--socket=") {
            index += 1
        }
        guard index < words.count, words[index] == "hooks" else {
            return false
        }

        let arguments = Array(words[index...])
        if arguments.count >= 3,
           arguments[1] == "hermes-agent" {
            return true
        }
        return arguments.count >= 6
            && arguments[1] == "feed"
            && arguments[2] == "--source"
            && arguments[3] == "hermes-agent"
            && arguments[4] == "--event"
            && !arguments[5].isEmpty
    }

    private func isCmuxExecutable(_ word: String) -> Bool {
        if ["$cmux_cli", "${cmux_cli}", "$CMUX_cli", "${CMUX_cli}"].contains(word) {
            return true
        }
        return URL(fileURLWithPath: word).lastPathComponent == "cmux"
    }

    private func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else {
            return false
        }
        let name = word[..<equals]
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private func shellSegments(in command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var wordStarted = false
        var quote = Quote.none
        var escaping = false

        for character in command {
            if escaping {
                word.append(character)
                wordStarted = true
                escaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = .none
                } else {
                    word.append(character)
                }
                continue
            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    escaping = true
                } else {
                    word.append(character)
                }
                continue
            case .none:
                break
            }

            if character == "'" {
                quote = .single
                wordStarted = true
            } else if character == "\"" {
                quote = .double
                wordStarted = true
            } else if character == "\\" {
                escaping = true
                wordStarted = true
            } else if ";|&{}()\n".contains(character) {
                if wordStarted {
                    words.append(word)
                    word = ""
                    wordStarted = false
                }
                if !words.isEmpty {
                    segments.append(words)
                    words = []
                }
            } else if character.isWhitespace {
                if wordStarted {
                    words.append(word)
                    word = ""
                    wordStarted = false
                }
            } else {
                word.append(character)
                wordStarted = true
            }
        }

        guard quote == .none, !escaping else { return [] }
        if wordStarted {
            words.append(word)
        }
        if !words.isEmpty {
            segments.append(words)
        }
        return segments
    }
}
