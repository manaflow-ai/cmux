public import CmuxNextAgentPane
public import CmuxNextCloud
import Foundation

// `cmux cloud start-session --mode MODE --team TEAM` (Leo, 2026-11-10: "did you guys not test these": Personal vs
// team, Bypass). The App's start passes both as the composer's Cloud send does; the rules stay in Rust.

extension AgentPaneSeed {
    /// A start-session chat tab's seed: its folder, and with `mode` that mode with the harness it is for, the way the
    /// composer's Cloud send seeds its pick (the remote start sends a seeded mode only for that harness, as
    /// `agent-session-start`'s `mode`; the machine applies it on the caller's own VM only, agent_session_start.rs).
    public static func cloudStart(cwd: String?, agent: String, mode: String?) -> AgentPaneSeed? {
        guard let mode else { return cwd.map { AgentPaneSeed(cwd: $0) } }
        return AgentPaneSeed(cwd: cwd, harness: agent, mode: mode)
    }
}

extension ActiveTeam {
    /// The team `--team` names when it is not the active one, by Rust's rule (`cloud_handler_team`: an id, a name,
    /// or `personal`, the person's own team); nil without `--team` or when it is active. Another team is refused.
    public func startTeam(_ team: String?, rules: CloudHandlerRules) throws -> String? {
        guard let team else { return nil }
        let facts: [String: Any] = ["teams": teams.map { ["id": $0.id, "name": $0.displayName] }, "active": id as Any, "team": team]
        return try rules.checked("cloud_handler_team", facts.compacted, valueKey: "select") as? String
    }

    /// `--team`: the switch the composer's Switch to <team> makes (``select(_:)``, as the team picker), then the
    /// same check that the start runs only in it (`cloud_start_refusal`).
    public func switchForStart(_ team: String?, signedIn: Bool, rules: CloudHandlerRules) async throws {
        guard let wanted = try startTeam(team, rules: rules) else { return }
        try await select(wanted)
        if let refused = CloudStartCore().refusal(cloudDisabled: false, signedIn: signedIn, requestedTeam: wanted, activeTeam: id) {
            throw ActionFailure(message: CloudStrings.startRefusal(refused))
        }
    }

    /// The account's teams as the team menu lists them, for `auth.status` (`teams`), so a script can name one to `--team`.
    public var statusRows: [[String: Any]] { rows.map { ["id": $0.id, "title": $0.title, "kind": $0.kind.rawValue, "active": $0.active] } }
}

/// `cmux cloud start-session`'s words, as a refusal or a pending answer gives the command to run again: every word as
/// the shell reads it back. `--from-folder` is a folder on this Mac copied there, never with `--cwd`; `--model` the
/// agent's model (nil: its harness default); `--mode` the permission mode it starts in (nil: the machine's own);
/// `--team` the team switched to first (nil: the active one).
public struct CloudStartSessionCommand: Equatable, Sendable {
    public var machineID: String?, name: String?, agent: String, model: String?, cwd: String?, fromFolder: String?
    public var login: String?, mode: String?, team: String?

    public init(machineID: String?, name: String?, agent: String, model: String?, cwd: String?, fromFolder: String?,
                login: String?, mode: String?, team: String?) {
        (self.machineID, self.name, self.agent, self.model, self.cwd, self.fromFolder) = (machineID, name, agent, model, cwd, fromFolder)
        (self.login, self.mode, self.team) = (login, mode, team)
    }

    public var text: String {
        let quoted = CloudStartCore.shellQuoted
        var words = ["cmux cloud start-session"]
        if let machineID { words.append("--target machine:" + quoted(machineID)) } else { words.append("--name " + quoted(name ?? "")) }
        words.append("--agent " + agent + (model.map { " --model " + quoted($0) } ?? ""))
        if let cwd { words.append("--cwd " + quoted(cwd)) }
        if let fromFolder { words.append("--from-folder " + quoted(fromFolder)) }
        if let login { words.append("--login " + login) }
        if let mode { words.append("--mode " + quoted(mode)) }
        if let team { words.append("--team " + quoted(team)) }
        return words.joined(separator: " ")
    }
}
