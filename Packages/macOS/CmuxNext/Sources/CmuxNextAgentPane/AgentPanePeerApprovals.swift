import CmuxNextCompat
import Foundation

/// Why a peer of this Mac's agent daemon (a chat opened with `--host`) did not count an allow
/// signed by this Mac (peer-route approvals, ``AcpmuxMacApprover``).
public nonisolated enum AgentPanePeerApprovals: Sendable, Equatable {
    /// The peer, by this Mac's daemon's name for it, has not enrolled this Mac.
    case notEnrolled(peer: String)
    /// The allow was not a one-time allow: only those count from this Mac.
    case onceOnly
}

/// This app's side of peer-route approvals (``AcpmuxMacApprover``): this Mac's approver key, the
/// local daemons its hosts gave that key to, and what a pane's Enroll this Mac runs. One per app:
/// the app's composition root makes it and hands it to its hosts and panes; a test makes its own.
@MainActor
public final class AgentPanePeerApprover {
    /// The key a one-time Allow on a peer's prompt is signed with.
    public nonisolated let key: AcpmuxMacApprover
    /// Enrolls this Mac's approver key on `peer` (`acpmux host approvals enroll PEER`, over the
    /// person's own ssh to that machine), run against the daemon `daemon` names (its
    /// `ACPMUX_HOME` and `ACPMUX_SOCKET`: the one this pane talks to, which knows `peer` and holds
    /// this Mac's key): nil once enrolled, else what failed, in that command's words. nil offers
    /// no Enroll button.
    public let enroll: ((_ peer: String, _ daemon: [String: String]) async -> String?)?
    /// The `ACPMUX_HOME` and `ACPMUX_SOCKET` of each local daemon this app gave its key to, by
    /// socket path: what a pane on that socket enrolls through.
    var daemons: [String: [String: String]] = [:]

    public init(key: AcpmuxMacApprover, enroll: ((_ peer: String, _ daemon: [String: String]) async -> String?)? = nil) {
        self.key = key
        self.enroll = enroll
    }

    /// The daemon a pane on `socket` enrolls through: the one this app registered there, else
    /// that socket alone.
    func daemon(socket: String?) -> [String: String] {
        guard let socket else { return [:] }
        return daemons[socket] ?? ["ACPMUX_SOCKET": socket]
    }

    /// Gives this Mac's acpmux the public key, so `acpmux host enroll` there knows which key to
    /// enroll on a peer (`_acpmux/mac_approver_set`, the person only), each time the host connects
    /// to that daemon (a restarted daemon holds none: `thisMac` is in its memory only). Off the
    /// pane's connect path.
    nonisolated func register(_ environment: AcpmuxEnvironment) {
        // task-owner: one short person connection (5 s deadline at most) per daemon connect
        Task { @MainActor in await self.registerNow(environment) }
    }

    private func registerNow(_ environment: AcpmuxEnvironment) async {
        daemons[environment.socketPath] = ["ACPMUX_HOME": environment.home.path, "ACPMUX_SOCKET": environment.socketPath]
        guard let identity = await key.loadedIdentity() else { return }
        guard let line = await AcpmuxPersonLine.open(environment) else { return }
        defer { line.close() }
        guard line.isPerson else { return }
        let name = await MacName().displayName()
        // nil: a daemon too old for peer-route approvals, nothing to give it.
        _ = await line.call("_acpmux/mac_approver_set", ["id": identity.id, "publicKey": identity.publicKey, "name": name])
    }
}
