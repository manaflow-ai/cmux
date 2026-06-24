public import Foundation

/// Argv parsing helpers for coding-agent resume/session detection, scoped to the
/// argument-vector value type `[String]` so call sites read as `arguments.value(afterOption:)`
/// rather than going through a free function. All option parsing is byte-faithful to
/// the agent CLIs cmux launches and resumes (claude, codex, opencode, grok, pi).
extension [String] {
    /// True when argv carries OpenCode's `--fork` flag, either bare or `--fork=…`.
    public var hasOpenCodeForkFlag: Bool {
        contains { $0 == "--fork" || $0.hasPrefix("--fork=") }
    }

    /// The parent session id from a `--fork=<id>` argument, trimmed; `nil` when no
    /// `--fork=` carries a non-empty value.
    public var openCodeForkParentSessionId: String? {
        for argument in self {
            let prefix = "--fork="
            guard argument.hasPrefix(prefix) else { continue }
            let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The value for `option`, accepting both `option value` and `option=value`
    /// forms; trims whitespace and returns `nil` for an empty value or a missing
    /// option.
    ///
    /// - Parameter option: The long/short option flag to read, e.g. `--session`.
    public func value(afterOption option: String) -> String? {
        for index in indices {
            let argument = self[index]
            if argument == option {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { return nil }
                let value = self[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let prefix = option + "="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Like `value(afterOption:)`, but rejects a value that begins with `-` (which
    /// would actually be the next option, not this option's value).
    ///
    /// - Parameter option: The option flag to read.
    public func nonOptionValue(afterOption option: String) -> String? {
        guard let value = value(afterOption: option), !value.hasPrefix("-") else {
            return nil
        }
        return value
    }

    /// The `pi`-compatible session id from `--session`/`--resume`/`-r` (space or
    /// `=` form), scanning from `startIndex` onward so the runtime's own options are
    /// skipped; `nil` when none carries a non-option value.
    ///
    /// - Parameter startIndex: The first argv index to consider (past the runtime
    ///   script argument).
    public func piCompatibleSessionID(startingAt startIndex: Int) -> String? {
        guard startIndex < endIndex else { return nil }
        for index in indices where index >= startIndex {
            let argument = self[index]
            if argument == "--session" || argument == "--resume" || argument == "-r" {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { continue }
                if let value = normalizedNonOptionValue(self[nextIndex]) {
                    return value
                }
                continue
            }
            if argument.hasPrefix("--session="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("--session=".count))) {
                return value
            }
            if argument.hasPrefix("--resume="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("--resume=".count))) {
                return value
            }
            if argument.hasPrefix("-r="),
               let value = normalizedNonOptionValue(String(argument.dropFirst("-r=".count))) {
                return value
            }
        }
        return nil
    }

    private func normalizedNonOptionValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.hasPrefix("-") ? value : nil
    }

    /// The Grok resume session id from `-r`/`--resume` (space or `=` form); `nil`
    /// when none carries a non-option value.
    public var grokResumeSessionID: String? {
        let options = ["-r", "--resume"]
        for index in indices {
            let argument = self[index]
            if options.contains(argument) {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { continue }
                let value = self[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
                continue
            }
            for option in options {
                let prefix = option + "="
                guard argument.hasPrefix(prefix) else { continue }
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !value.hasPrefix("-") {
                    return value
                }
            }
        }
        return nil
    }
}
