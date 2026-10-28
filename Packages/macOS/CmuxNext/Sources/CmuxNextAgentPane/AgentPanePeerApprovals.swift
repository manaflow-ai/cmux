import Foundation

/// Why a peer of this Mac's agent daemon (a chat opened with `--host`) did not count an allow
/// signed by this Mac (peer-route approvals, ``AcpmuxMacApprover``).
public nonisolated enum AgentPanePeerApprovals: Sendable, Equatable {
    /// The peer, by this Mac's daemon's name for it, has not enrolled this Mac.
    case notEnrolled(peer: String)
    /// The allow was not a one-time allow: only those count from this Mac.
    case onceOnly

    /// Enrolls this Mac's approver key on `peer` (`acpmux host approvals enroll PEER`, over the
    /// person's own ssh to that machine), run against the daemon `daemon` names (its
    /// `ACPMUX_HOME` and `ACPMUX_SOCKET`: the one this pane talks to, which knows `peer` and holds
    /// this Mac's key): nil once enrolled, else what failed, in that command's words. The app sets
    /// it at launch; nil offers no Enroll button.
    @MainActor public static var enroll: ((_ peer: String, _ daemon: [String: String]) async -> String?)?

    /// The `ACPMUX_HOME` and `ACPMUX_SOCKET` of each local daemon this app gave its key to
    /// (``AcpmuxMacApprover``), by socket path: what a pane on that socket enrolls through.
    @MainActor static var daemons: [String: [String: String]] = [:]

    /// The daemon a pane on `socket` enrolls through: the one this app registered there, else
    /// that socket alone.
    @MainActor static func daemon(socket: String?) -> [String: String] {
        guard let socket else { return [:] }
        return daemons[socket] ?? ["ACPMUX_SOCKET": socket]
    }
}
