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

    /// The explicit resume/session id carried by any of `options` (space form,
    /// `option value`) or `valuePrefixes` (`option=value` form), trimmed of
    /// surrounding whitespace and newlines; `nil` when no such option carries a
    /// non-empty value.
    ///
    /// Byte-faithful to the agent CLI argv scan cmux uses for explicit session
    /// detection: the space form requires the following token to not begin with
    /// `-` (so it is a value, not the next option), while the `=` form accepts any
    /// non-empty trimmed value. Kind-agnostic: the caller supplies the option set
    /// for the specific agent (claude, codex, …) so no agent enum leaks here.
    ///
    /// - Parameters:
    ///   - options: The flag tokens whose following argv element is the value,
    ///     e.g. `["--resume", "-r", "--session-id"]`.
    ///   - valuePrefixes: The `option=` prefixes whose remainder is the value,
    ///     e.g. `["--resume=", "--session-id="]`.
    public func explicitSessionID(options: Set<String>, valuePrefixes: [String]) -> String? {
        var index = startIndex
        while index < endIndex {
            let argument = self[index]
            if options.contains(argument),
               index + 1 < endIndex,
               !self[index + 1].hasPrefix("-") {
                return Self.normalizedSessionValue(self[index + 1])
            }
            for prefix in valuePrefixes where argument.hasPrefix(prefix) {
                return Self.normalizedSessionValue(String(argument.dropFirst(prefix.count)))
            }
            index += 1
        }
        return nil
    }

    /// The value of the first positional argument that immediately follows `token`
    /// (e.g. codex's `resume <id>` subcommand form), trimmed; `nil` when `token`
    /// is absent, is the last element, or is followed by something beginning with
    /// `-`.
    ///
    /// - Parameter token: The positional subcommand token, e.g. `"resume"`.
    public func positionalSessionID(afterToken token: String) -> String? {
        guard let index = firstIndex(of: token),
              index + 1 < endIndex,
              !self[index + 1].hasPrefix("-") else {
            return nil
        }
        return Self.normalizedSessionValue(self[index + 1])
    }

    private static func normalizedSessionValue(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
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
