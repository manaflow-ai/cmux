import Foundation

extension AgentResumeArgvParser {
    /// The explicit Claude resume/session id carried by `--resume`, `-r`, or
    /// `--session-id` (in either `--opt value` or `--opt=value` form), or `nil`
    /// when none is present. Mirrors the value cmux re-attaches a detected live
    /// `claude` process to.
    public func claudeExplicitResumeSessionId(in arguments: [String]) -> String? {
        sessionId(
            in: arguments,
            afterAnyOption: ["--resume", "-r", "--session-id"],
            valuePrefixes: ["--resume=", "--session-id="]
        )
    }

    /// The explicit Codex resume id carried by `--resume`/`-r` (in either
    /// `--opt value` or `--opt=value` form), falling back to the bare
    /// `codex resume <id>` subcommand positional when no option is present; `nil`
    /// when neither carries a non-option value.
    public func codexExplicitResumeSessionId(in arguments: [String]) -> String? {
        if let id = sessionId(in: arguments, afterAnyOption: ["--resume", "-r"], valuePrefixes: ["--resume="]) {
            return id
        }
        if let index = arguments.firstIndex(of: "resume"),
           index + 1 < arguments.endIndex,
           !arguments[index + 1].hasPrefix("-") {
            let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
