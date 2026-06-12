import Foundation
import CMUXAgentLaunch


nonisolated enum TerminalStartupWorkingDirectoryPrefix {
    private static func optionalChangeDirectoryPrefix(for workingDirectory: String?) -> String? {
        guard let workingDirectory = normalized(workingDirectory) else { return nil }
        let quoted = TerminalStartupShellQuoting.singleQuoted(workingDirectory)
        return "{ cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ]; } && "
    }

    static func prefix(_ command: String, workingDirectory: String?) -> String {
        guard let prefix = optionalChangeDirectoryPrefix(for: workingDirectory) else {
            return command
        }
        return prefix + command
    }

    static func replacingRequiredChangeDirectoryPrefix(
        in command: String,
        workingDirectory: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workingDirectory = normalized(workingDirectory) else { return trimmed }
        let stripped = strippedRequiredChangeDirectoryPrefix(
            from: trimmed,
            workingDirectory: workingDirectory
        )
        let command = strippedSavedWorkingDirectoryOptions(
            from: stripped,
            workingDirectory: workingDirectory
        )
        return prefix(command, workingDirectory: workingDirectory)
    }

    private static func strippedRequiredChangeDirectoryPrefix(
        from command: String,
        workingDirectory: String
    ) -> String {
        let quotedCandidates = [
            TerminalStartupShellQuoting.singleQuoted(workingDirectory),
            legacySingleQuoted(workingDirectory)
        ]
        var seen = Set<String>()
        for quoted in quotedCandidates where seen.insert(quoted).inserted {
            let prefixes = [
                "{ cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ]; } && ",
                "{ [ ! -d \(quoted) ] || cd -- \(quoted); } && ",
                "cd -- \(quoted) && ",
                "cd \(quoted) && "
            ]
            for prefix in prefixes where command.hasPrefix(prefix) {
                return String(command.dropFirst(prefix.count))
            }
        }
        return command
    }

    private static func strippedSavedWorkingDirectoryOptions(
        from command: String,
        workingDirectory: String
    ) -> String {
        let words = shellWordRanges(command)
        let ranges = savedWorkingDirectoryOptionRanges(
            in: words,
            workingDirectory: workingDirectory
        )
        guard !ranges.isEmpty else { return command }
        return removingRanges(removing: ranges, from: command)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func legacySingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ShellWordRange {
        var value: String
        var range: Range<String.Index>
    }

    private static func shellWordRanges(_ command: String) -> [ShellWordRange] {
        enum Quote {
            case single
            case double
        }

        var words: [ShellWordRange] = []
        var current = ""
        var wordStart: String.Index?
        var quote: Quote?
        var hasCurrentWord = false
        let doubleQuoteEscapable: Set<Character> = ["$", "`", "\"", "\\", "\n"]

        func markWordStart(_ index: String.Index) {
            if wordStart == nil {
                wordStart = index
            }
            hasCurrentWord = true
        }

        func finishWord(at end: String.Index) {
            guard hasCurrentWord else { return }
            words.append(ShellWordRange(value: current, range: (wordStart ?? end)..<end))
            current = ""
            wordStart = nil
            hasCurrentWord = false
        }

        var index = command.startIndex
        while index < command.endIndex {
            let character = command[index]
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                markWordStart(index)
                quote = .single
            case (nil, "\""):
                markWordStart(index)
                quote = .double
            case (.double, "\\"):
                markWordStart(index)
                let next = command.index(after: index)
                if next < command.endIndex,
                   doubleQuoteEscapable.contains(command[next]) {
                    current.append(command[next])
                    index = command.index(after: next)
                    continue
                }
                current.append(character)
            case (nil, "\\"):
                markWordStart(index)
                let next = command.index(after: index)
                if next < command.endIndex {
                    current.append(command[next])
                    index = command.index(after: next)
                    continue
                }
                current.append(character)
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord(at: index)
            default:
                markWordStart(index)
                current.append(character)
            }
            index = command.index(after: index)
        }
        finishWord(at: command.endIndex)
        return words
    }

    private static func savedWorkingDirectoryOptionRanges(
        in words: [ShellWordRange],
        workingDirectory: String
    ) -> [Range<String.Index>] {
        let valueOptions: Set<String> = ["--cd", "-C", "--cwd", "--workspace", "-w"]
        let optionPrefixes = valueOptions.map { "\($0)=" }
        var ranges: [Range<String.Index>] = []
        var index = 0
        while index < words.count {
            let arg = words[index].value
            if arg == "--" {
                break
            }
            if valueOptions.contains(arg),
               index + 1 < words.count,
               workingDirectoryValue(words[index + 1].value, matches: workingDirectory) {
                ranges.append(words[index].range.lowerBound..<words[index + 1].range.upperBound)
                index += 2
                continue
            }
            if let prefix = optionPrefixes.first(where: { arg.hasPrefix($0) }) {
                let value = String(arg.dropFirst(prefix.count))
                if workingDirectoryValue(value, matches: workingDirectory) {
                    ranges.append(words[index].range)
                    index += 1
                    continue
                }
            }
            index += 1
        }
        return ranges
    }

    private static func removingRanges(
        removing ranges: [Range<String.Index>],
        from command: String
    ) -> String {
        let expanded = ranges.map { range -> Range<String.Index> in
            var lower = range.lowerBound
            var upper = range.upperBound
            if lower == command.startIndex {
                while upper < command.endIndex, command[upper].isWhitespace {
                    upper = command.index(after: upper)
                }
            } else {
                while lower > command.startIndex {
                    let before = command.index(before: lower)
                    guard command[before].isWhitespace else { break }
                    lower = before
                }
            }
            return lower..<upper
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<String.Index>] = []
        for range in expanded {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                let upper = last.upperBound < range.upperBound ? range.upperBound : last.upperBound
                merged[merged.count - 1] = last.lowerBound..<upper
            } else {
                merged.append(range)
            }
        }

        var result = ""
        var cursor = command.startIndex
        for range in merged {
            result.append(contentsOf: command[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: command[cursor..<command.endIndex])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func workingDirectoryValue(_ value: String, matches workingDirectory: String) -> Bool {
        guard value == workingDirectory else {
            return (value as NSString).expandingTildeInPath == (workingDirectory as NSString).expandingTildeInPath
        }
        return true
    }
}

