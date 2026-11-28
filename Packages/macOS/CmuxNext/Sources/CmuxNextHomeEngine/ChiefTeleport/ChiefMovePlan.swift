/// The steps of one Chief move (chief-migration-DESIGN.md 8a): a dry run whose report the person reads,
/// the move, then `move reach` on the target. Each step is the bundled `cmux` CLI's arguments (`cmux
/// chief move …`, one implementation with the CLI and MCP), except reach on an SSH host or paired
/// server, which runs there. Every step names the app's Chief home (`--chief-home`), so a tagged build
/// moves its own Chief, never the one the CLI would pick by itself. A Cloud session token goes through
/// a 0600 file, never the command line.
public nonisolated struct ChiefMovePlan: Equatable, Sendable {
    /// Where `move reach` runs.
    public enum Reach: Equatable, Sendable {
        /// The bundled `cmux` CLI's arguments.
        case cli([String])
        /// A command run as is on this Mac (`ssh … optchat-chief move reach`).
        case remote([String])
        /// No home to probe (a Cloud Chief lives in the account).
        case none
    }

    /// `cmux chief move --to … --dry-run`.
    public let dryRun: [String]
    /// `cmux chief move --to …`.
    public let move: [String]
    public let reach: Reach

    /// - Parameters:
    ///   - to: the target's `--to` value.
    ///   - kind: the target's kind.
    ///   - sourceHome: the app's Chief home, the one that moves (`ChiefHome.resolve(tag:).root`).
    ///   - targetHome: where an SSH target keeps the Chief home (``targetHome(home:userHome:)``).
    ///   - tokenFile: a 0600 file holding the Cloud session token, for a Cloud target.
    public init(to: String, kind: ChiefMoveTargets.Kind, sourceHome: String, targetHome: String, tokenFile: String?) {
        let plan: WirePlan = dockRule("dock.move_plan",
                                      PlanRequest(to: to, kind: WireKind(kind), sourceHome: sourceHome, targetHome: targetHome, tokenFile: tokenFile),
                                      fallback: WirePlan(dryRun: [], move: [], reach: WireReach(type: "none", args: nil)))
        dryRun = plan.dryRun
        move = plan.move
        switch plan.reach.type {
        case "cli": reach = .cli(plan.reach.args ?? [])
        case "remote": reach = .remote(plan.reach.args ?? [])
        default: reach = .none
        }
    }

    /// `cmux chief move rollback` on the app's Chief home: it answers here again and the target is
    /// marked moved back. Out of cmux Cloud the hosted brain is turned off, which takes the session
    /// (`tokenFile`, a 0600 file).
    public static func rollback(sourceHome: String, tokenFile: String?) -> [String] {
        dockRule("dock.move_rollback", RollbackRequest(sourceHome: sourceHome, tokenFile: tokenFile), fallback: [])
    }

    /// The moving home's path under the user's home folder as `~/…` (the same place on the target, as
    /// `optchat-chief move` puts it); a home outside that folder keeps its path.
    public static func targetHome(home: String, userHome: String) -> String {
        dockRule("dock.move_target_home", ["home": home, "userHome": userHome], fallback: home)
    }

    private struct PlanRequest: Encodable {
        var to: String
        var kind: WireKind
        var sourceHome: String
        var targetHome: String
        var tokenFile: String?
    }

    private struct RollbackRequest: Encodable {
        var sourceHome: String
        var tokenFile: String?
    }

    private struct WireReach: Decodable {
        var type: String
        var args: [String]?
    }

    private struct WirePlan: Decodable {
        var dryRun: [String]
        var move: [String]
        var reach: WireReach
    }
}
