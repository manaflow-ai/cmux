/// The steps of one Chief move (chief-migration-DESIGN.md 8a): a dry run whose report the person reads,
/// the move, then `move reach` on the target. Each step is the bundled `cmux` CLI's arguments (`cmux
/// chief move …`, one implementation with the CLI and MCP), except reach on an SSH host or paired
/// server, which runs there. A Cloud session token goes through a 0600 file, never the command line.
struct ChiefMovePlan: Equatable {
    /// Where `move reach` runs.
    enum Reach: Equatable {
        /// The bundled `cmux` CLI's arguments.
        case cli([String])
        /// A command run as is on this Mac (`ssh … optchat-chief move reach`).
        case remote([String])
        /// No home to probe (a Cloud Chief lives in the account).
        case none
    }

    let dryRun: [String]
    let move: [String]
    let reach: Reach

    /// - Parameters:
    ///   - to: the target's `--to` value.
    ///   - kind: the target's kind.
    ///   - targetHome: where an SSH target keeps the Chief home (``targetHome(home:userHome:)``).
    ///   - tokenFile: a 0600 file holding the Cloud session token, for a Cloud target.
    init(to: String, kind: ChiefMoveTargets.Kind, targetHome: String, tokenFile: String?) {
        let token = tokenFile.map { ["--session-token-file", $0] } ?? []
        dryRun = ["chief", "move", "--to", to, "--dry-run"] + token
        move = ["chief", "move", "--to", to] + token
        switch kind {
        case .local(let home): reach = .cli(["chief", "move", "reach", "--chief-home", home])
        case .ssh(let destination), .server(let destination?):
            reach = .remote(["ssh", "-o", "BatchMode=yes", destination, "optchat-chief", "move", "reach", "--home", targetHome])
        case .server(nil), .cloud: reach = .none
        }
    }

    /// The moving home's path under the user's home folder as `~/…` (the same place on the target, as
    /// `optchat-chief move` puts it); a home outside that folder keeps its path.
    static func targetHome(home: String, userHome: String) -> String {
        let base = userHome.hasSuffix("/") ? userHome : userHome + "/"
        return home.hasPrefix(base) ? "~/" + home.dropFirst(base.count) : home
    }
}
