import Foundation

/// Builds and rewrites the `cd`-into-working-directory prefix that cmux prepends to a restored
/// terminal surface's startup command.
///
/// The prefix is `cd -- '<dir>' 2>/dev/null || [ ! -d '<dir>' ] && ` (brace-free for fish-login
/// safety, #6328/#6285), which changes into the working directory when it still exists and otherwise
/// runs the command in place rather than failing. The rewriting path also strips any previously-saved
/// prefix shape (including the older braced and `cd --`/`cd` forms and legacy single-quoting) and
/// removes saved `--cd`/`-C`/`--cwd`/`--workspace`/`-w`
/// options whose value matches the working directory, so re-restoring a session does not stack
/// duplicate `cd`s.
///
/// The type is a stateless value; construct one at the call site
/// (`TerminalStartupWorkingDirectoryPrefix()`) rather than reaching through a static namespace, per
/// the package design discipline.
public struct TerminalStartupWorkingDirectoryPrefix: Sendable, Equatable {
    /// Creates a working-directory prefix builder. The type holds no state.
    public init() {}

    /// The `cd`-into-`workingDirectory` prefix for a startup command, or `nil` when `workingDirectory`
    /// is absent (empty or whitespace once trimmed).
    public func optionalChangeDirectoryPrefix(for workingDirectory: String?) -> String? {
        guard let workingDirectory = normalized(workingDirectory) else { return nil }
        let quoted = TerminalStartupShellQuoting().singleQuoted(workingDirectory)
        // Brace-free form (#6328/#6285): cmux resumes agents via `/usr/bin/login`
        // → `$SHELL`, and a fish login shell errors on POSIX `{ …; }` grouping and
        // drops the tab to a bare prompt. `&&`/`||` are equal-precedence and
        // left-associative in POSIX sh, so this parses as `(cd || [ ! -d ]) && cmd`
        // exactly like the braced form, but is fish-safe.
        return "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && "
    }

    /// Prepends the ``optionalChangeDirectoryPrefix(for:)`` to `command`, returning `command`
    /// unchanged when `workingDirectory` is absent.
    public func prefix(_ command: String, workingDirectory: String?) -> String {
        guard let prefix = optionalChangeDirectoryPrefix(for: workingDirectory) else {
            return command
        }
        return prefix + command
    }

    /// Normalizes `command` so it carries exactly one current `cd` prefix for `workingDirectory`.
    ///
    /// Trims `command`, strips any prior `cd` prefix shape and any saved working-directory option
    /// pointing at `workingDirectory`, then re-applies the current prefix. With `workingDirectory`
    /// absent it returns the trimmed command unchanged.
    public func replacingRequiredChangeDirectoryPrefix(
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

    /// Normalizes `command` by first stripping a prefix for
    /// `previousWorkingDirectory`, then applying the current `workingDirectory`
    /// prefix.
    public func replacingRequiredChangeDirectoryPrefix(
        in command: String,
        previousWorkingDirectory: String?,
        workingDirectory: String?
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = normalized(previousWorkingDirectory).map {
            strippedSavedWorkingDirectoryOptions(
                from: strippedRequiredChangeDirectoryPrefix(from: trimmed, workingDirectory: $0),
                workingDirectory: $0
            )
        } ?? trimmed
        return replacingRequiredChangeDirectoryPrefix(
            in: stripped,
            workingDirectory: workingDirectory
        )
    }

    private func strippedRequiredChangeDirectoryPrefix(
        from command: String,
        workingDirectory: String
    ) -> String {
        let quotedCandidates = [
            TerminalStartupShellQuoting().singleQuoted(workingDirectory),
            legacySingleQuoted(workingDirectory)
        ]
        var seen = Set<String>()
        for quoted in quotedCandidates where seen.insert(quoted).inserted {
            let prefixes = [
                "cd -- \(quoted) 2>/dev/null || [ ! -d \(quoted) ] && ",
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

    private func strippedSavedWorkingDirectoryOptions(
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

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func legacySingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ShellWordRange {
        var value: String
        var range: Range<String.Index>
    }

    private func shellWordRanges(_ command: String) -> [ShellWordRange] {
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

    private func savedWorkingDirectoryOptionRanges(
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

    private func removingRanges(
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

    private func workingDirectoryValue(_ value: String, matches workingDirectory: String) -> Bool {
        guard value == workingDirectory else {
            return (value as NSString).expandingTildeInPath == (workingDirectory as NSString).expandingTildeInPath
        }
        return true
    }
}
