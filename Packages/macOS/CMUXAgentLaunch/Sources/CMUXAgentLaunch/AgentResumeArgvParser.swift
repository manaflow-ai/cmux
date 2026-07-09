import Foundation

/// Parses an agent process's captured argument vector for the session/resume
/// identifiers cmux needs to re-attach to a running agent.
///
/// This is the read side that mirrors ``AgentResumeArgv`` (which *builds* a resume argv):
/// given the argv cmux observed for a live process (OpenCode fork flags, `--session`/`--resume`/`-r`
/// options, pi-style positional session ids, grok resume ids), it extracts the value cmux uses to
/// identify the resumable session. It is pure value logic over `[String]` (no `AppKit`, `Process`, or
/// socket), so it is testable in isolation.
///
/// The type is a stateless value; construct one at the call site (`AgentResumeArgvParser()`) rather
/// than reaching through a static namespace, per the package design discipline.
public struct AgentResumeArgvParser: Sendable, Equatable {
    /// Creates an argv parser. The type holds no state.
    public init() {}

    /// Whether `arguments` requests an OpenCode fork (`--fork` or `--fork=<id>`).
    public func hasOpenCodeForkFlag(in arguments: [String]) -> Bool {
        arguments.contains { $0 == "--fork" || $0.hasPrefix("--fork=") }
    }

    /// The parent session id assigned by an OpenCode `--fork=<id>` flag, or `nil` when no
    /// `--fork=` carries a non-empty value.
    public func openCodeForkParentSessionId(in arguments: [String]) -> String? {
        for argument in arguments {
            let prefix = "--fork="
            guard argument.hasPrefix(prefix) else { continue }
            let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The value following `option` in `arguments`, accepting both `--opt value` and `--opt=value`
    /// forms, trimmed; `nil` when absent or empty.
    public func value(in arguments: [String], afterOption option: String) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == option {
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else { return nil }
                let value = arguments[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Like ``value(in:afterOption:)`` but rejects a value that itself looks like an option
    /// (`-`-prefixed), so a missing argument cannot be mistaken for the next flag.
    public func nonOptionValue(in arguments: [String], afterOption option: String) -> String? {
        guard let value = value(in: arguments, afterOption: option), !value.hasPrefix("-") else {
            return nil
        }
        return value
    }

    /// The pi-compatible session id from `--session`/`--resume`/`-r` (space- or `=`-joined), scanning
    /// from `startIndex`; `nil` when none carries a non-option value.
    public func piCompatibleSessionID(in arguments: [String], startingAt startIndex: Int) -> String? {
        guard startIndex < arguments.endIndex else { return nil }
        for index in arguments.indices where index >= startIndex {
            let argument = arguments[index]
            if argument == "--session" || argument == "--resume" || argument == "-r" {
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else { continue }
                if let value = normalizedNonOptionValue(arguments[nextIndex]) {
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

    /// The first session id introduced by any of `options` in `--opt value` form (the following value
    /// must not be `-`-prefixed) or by any of `valuePrefixes` in `--opt=value` form, scanning `arguments`
    /// left to right; trimmed, `nil` when none carries a non-empty value.
    ///
    /// Unlike ``grokResumeSessionID(in:)`` the `valuePrefixes` are passed independently of `options`, so a
    /// caller can accept `--resume=<id>` without also accepting `-r=<id>` (the Claude/Codex explicit-resume
    /// shapes). A `=`-joined value is only trimmed, not rejected for a leading `-`.
    public func sessionId(
        in arguments: [String],
        afterAnyOption options: Set<String>,
        valuePrefixes: [String]
    ) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if options.contains(argument),
               index + 1 < arguments.endIndex,
               !arguments[index + 1].hasPrefix("-") {
                return trimmedNonEmptyValue(arguments[index + 1])
            }
            for prefix in valuePrefixes where argument.hasPrefix(prefix) {
                return trimmedNonEmptyValue(String(argument.dropFirst(prefix.count)))
            }
            index += 1
        }
        return nil
    }

    private func trimmedNonEmptyValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The grok resume session id from `-r`/`--resume` (space- or `=`-joined), trimmed and
    /// non-option; `nil` when absent.
    public func grokResumeSessionID(in arguments: [String]) -> String? {
        let options = ["-r", "--resume"]
        for index in arguments.indices {
            let argument = arguments[index]
            if options.contains(argument) {
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else { continue }
                let value = arguments[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
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
