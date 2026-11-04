import Foundation

/// Which machine New Cloud Workspace (`cmux cloud new-workspace`) opens on. One workspace, one new
/// small machine (leo-workspace `design/cloud.md`, "One workspace per small machine", rule 1): with
/// no machine named, a workspace gets a new machine of its own, never one picked from the machines
/// already listed. The list holds the team's machines too (a teammate's, a fleet lane VM), and a
/// machine bound to one workspace is never picked for another.
///
/// Before, a CLI or agent run with no `--target` took the focused window's machine, else the only
/// one, else the first connected one in sidebar order, and so opened on a team's fleet lane VM.
public nonisolated enum CloudNewWorkspaceMachine: Sendable, Equatable {
    /// `--target machine:<id>`: that machine, refused when it is not there.
    case named(String)
    /// The person's own gesture in a window that shows a Cloud machine: "the machine I'm looking at".
    case focused(String)
    /// A new machine of the workspace's own.
    case new

    /// `named`: the machine a `--target machine:<id>` names. `byPerson`: the person's own gesture in
    /// this app (not a CLI, MCP, agent or script run, even one that claims the user's origin).
    /// `focused`: the Cloud machine the active window shows, if any.
    public static func pick(named: String?, byPerson: Bool, focused: String?) -> Self {
        if let named, !named.isEmpty { return .named(named) }
        if byPerson, let focused, !focused.isEmpty { return .focused(focused) }
        return .new
    }
}
