import Foundation

/// A herdr client attach found in a terminal's foreground process.
///
/// herdr keeps its server and every agent pane running when cmux quits; the
/// client in the cmux surface is the only thing that goes away, so re-running
/// this attach is the whole restore.
public struct HerdrResumeInvocation: Equatable, Sendable {
    /// The herdr executable as the process named it, path included.
    public let executable: String
    /// The attached session, or nil for herdr's default session.
    public let sessionName: String?
    /// The directory the attach ran in, when the process environment names one.
    public let workingDirectory: String?

    /// The attach in its normalized form: `herdr` or `herdr --session <name>`.
    public var arguments: [String] {
        guard let sessionName else { return [executable] }
        return [executable, "--session", sessionName]
    }

    /// ``arguments`` single-quoted for a POSIX shell.
    public var shellCommand: String {
        arguments.map(Self.shellSingleQuoted).joined(separator: " ")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension HerdrResumeInvocation {
    /// Set by herdr inside every pane it hosts. A herdr client started there is
    /// nested in another herdr, not the surface's own attach.
    public static let nestedEnvironmentKey = "HERDR_ENV"

    /// Names the session that a bare `herdr` attaches to. A session argument
    /// takes precedence over it.
    private static let sessionEnvironmentKey = "HERDR_SESSION"

    /// Recognizes a live herdr client from its process arguments and environment,
    /// or returns nil when the process is not a herdr client attach that a
    /// relaunch may repeat.
    ///
    /// Only the three attach forms are accepted: `herdr`, `herdr --session <name>`
    /// and `herdr session attach <name>`. Everything else fails closed: the
    /// detached `herdr server`, socket subcommands such as `herdr pane list`,
    /// remote attaches (`--remote`, `--machine`) and any unknown option.
    ///
    /// A bare `herdr` attaches to the session in `HERDR_SESSION`, like herdr
    /// itself, and the relaunch names that session explicitly.
    ///
    /// Unlike tmux, herdr does not rewrite its process title, so `argv[0]` is the
    /// authority. A process whose arguments are missing is rejected rather than
    /// read as a bare `herdr` attach.
    public init?(arguments: [String], environment: [String: String]) {
        guard !Self.isInsideHerdrPane(environment: environment),
              let executable = Self.normalized(arguments.first),
              Self.argumentLooksLikeHerdr(executable),
              let session = Self.parseAttach(Array(arguments.dropFirst()), environment: environment) else {
            return nil
        }
        self.init(
            executable: executable,
            sessionName: session.value,
            workingDirectory: Self.normalized(environment["CMUX_AGENT_LAUNCH_CWD"])
                ?? Self.normalized(environment["PWD"])
        )
    }

    /// A process running inside a herdr pane inherits the cmux surface
    /// variables of whichever surface first started the herdr server. It
    /// lives on herdr's own PTY, so it must never stand in for a cmux surface.
    public static func isInsideHerdrPane(environment: [String: String]) -> Bool {
        normalized(environment[nestedEnvironmentKey]) == "1"
    }

    /// True when the executable's file name is `herdr`, in any letter case.
    private static func argumentLooksLikeHerdr(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "herdr"
    }

    /// The session an attach names. `value` is nil for the default session.
    private struct AttachedSession {
        let value: String?
    }

    /// Accepts the attach forms after `argv[0]` and nothing else.
    private static func parseAttach(
        _ arguments: [String],
        environment: [String: String]
    ) -> AttachedSession? {
        switch arguments.count {
        case 0:
            return environmentSession(environment[sessionEnvironmentKey])
        case 1:
            let prefix = "--session="
            guard arguments[0].hasPrefix(prefix) else { return nil }
            return sessionName(String(arguments[0].dropFirst(prefix.count)))
                .map { AttachedSession(value: $0) }
        case 2:
            guard arguments[0] == "--session" else { return nil }
            return sessionName(arguments[1]).map { AttachedSession(value: $0) }
        case 3:
            guard arguments[0] == "session", arguments[1] == "attach" else { return nil }
            return sessionName(arguments[2]).map { AttachedSession(value: $0) }
        default:
            return nil
        }
    }

    /// The session a bare attach uses. An unset or empty `HERDR_SESSION` is
    /// herdr's default session. herdr silently falls back to that default for
    /// a name it rejects, so only a plain name (ASCII letters, digits, `.`,
    /// `_` and `-`, not starting with `-`) is kept. Any other value fails closed.
    private static func environmentSession(_ rawValue: String?) -> AttachedSession? {
        guard let rawValue, !rawValue.isEmpty else {
            return AttachedSession(value: nil)
        }
        let allowed = CharacterSet(charactersIn: "._-")
        guard !rawValue.hasPrefix("-"),
              rawValue.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || allowed.contains($0))
              }) else {
            return nil
        }
        return AttachedSession(value: rawValue)
    }

    /// A session name that is not empty, not an option and free of control characters.
    private static func sessionName(_ rawValue: String) -> String? {
        guard let value = normalized(rawValue),
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    /// The value without surrounding whitespace, or nil when nothing is left.
    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
