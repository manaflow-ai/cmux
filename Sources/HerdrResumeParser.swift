import Foundation

/// Recognizes a live herdr client in a terminal surface so a relaunch can
/// reattach it. herdr keeps its server and every agent pane running when cmux
/// quits; the client in the cmux surface is the only thing that goes away, so
/// re-running the attach is the whole restore.
///
/// Only the three attach forms are accepted: `herdr`, `herdr --session <name>`
/// and `herdr session attach <name>`. Everything else fails closed: the
/// detached `herdr server`, socket subcommands such as `herdr pane list`,
/// remote attaches (`--remote`, `--machine`) and any unknown option.
///
/// Unlike tmux, herdr does not rewrite its process title, so `argv[0]` is the
/// authority. A process whose arguments are missing is rejected rather than
/// read as a bare `herdr` attach.
enum HerdrResumeParser {
    /// Set by herdr inside every pane it hosts. A herdr client started there is
    /// nested in another herdr, not the surface's own attach.
    static let nestedEnvironmentKey = "HERDR_ENV"

    static func binding(
        arguments: [String],
        environment: [String: String],
        capturedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot? {
        guard !isInsideHerdrPane(environment: environment),
              let executable = normalized(arguments.first),
              argumentLooksLikeHerdr(executable),
              let attach = parseAttach(Array(arguments.dropFirst())) else {
            return nil
        }

        var argv = [executable]
        if let sessionName = attach.sessionName {
            argv.append(contentsOf: ["--session", sessionName])
        }
        let command = argv.map(shellSingleQuoted).joined(separator: " ")
        let cwd = normalized(environment["CMUX_AGENT_LAUNCH_CWD"] ?? environment["PWD"])
        return SurfaceResumeBindingSnapshot(
            name: attach.sessionName.map { "herdr \($0)" } ?? "herdr",
            kind: "herdr",
            command: command,
            cwd: cwd,
            checkpointId: attach.sessionName,
            source: "process-detected",
            environment: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: argv.first,
                arguments: argv,
                workingDirectory: cwd,
                environment: nil,
                capturedAt: capturedAt,
                source: "process-detected"
            ),
            autoResume: true,
            updatedAt: capturedAt
        )
    }

    /// A process running inside a herdr pane inherits the cmux surface
    /// variables of whichever surface first started the herdr server. It
    /// lives on herdr's own PTY, so it must never stand in for a cmux surface.
    static func isInsideHerdrPane(environment: [String: String]) -> Bool {
        normalized(environment[nestedEnvironmentKey]) == "1"
    }

    static func argumentLooksLikeHerdr(_ argument: String) -> Bool {
        let normalized = argument.lowercased()
        let pathComponents = (normalized as NSString).pathComponents
        let basename = pathComponents.last ?? normalized
        return basename == "herdr"
    }

    private struct HerdrAttach {
        let sessionName: String?
    }

    private static func parseAttach(_ arguments: [String]) -> HerdrAttach? {
        switch arguments.count {
        case 0:
            return HerdrAttach(sessionName: nil)
        case 1:
            let prefix = "--session="
            guard arguments[0].hasPrefix(prefix) else { return nil }
            return sessionName(String(arguments[0].dropFirst(prefix.count)))
                .map { HerdrAttach(sessionName: $0) }
        case 2:
            guard arguments[0] == "--session" else { return nil }
            return sessionName(arguments[1]).map { HerdrAttach(sessionName: $0) }
        case 3:
            guard arguments[0] == "session", arguments[1] == "attach" else { return nil }
            return sessionName(arguments[2]).map { HerdrAttach(sessionName: $0) }
        default:
            return nil
        }
    }

    private static func sessionName(_ rawValue: String) -> String? {
        guard let value = normalized(rawValue),
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
