public import CmuxNextCloud
import Foundation
import os

/// A Cloud start's last check before the first chat opens on its machine: once the machine runs the
/// app's own machine software, its agents must reach models through the machine's edge with no provider
/// login on it (plans/cmux-next/vm-coderouter-edge.md). The machine prints its model-route report
/// (`cmux-tui acp --json machine-auth`) and Rust judges it (cmux-cloud-start-core `machine_route`, op
/// `cloud_machine_route`); a refusal ends the start with its reason instead of a chat whose first turn the
/// provider rejects.
public struct CloudMachineRoute: Sendable {
    /// One command on the machine (the Cloud API's exec): the command and its timeout in milliseconds.
    public typealias Exec = @Sendable (_ command: String, _ timeoutMs: Int) async throws -> CloudExecResult

    /// What Rust answered about the machine's report.
    public enum Verdict: String, Decodable, Sendable {
        case ready, unsupported, invalid
        case noDaemon = "no_daemon"
        case holdsCredential = "holds_credential"
        case notEdge = "not_edge"
    }

    /// The start ends here: `verdict` says why.
    public struct Refused: Error, Sendable {
        public let verdict: Verdict
        /// The start card's text.
        public var message: String { CloudMachineRoute.message(verdict) }
    }

    /// The report's bound on the machine: one exec, well under the Cloud API's 5 minutes.
    public static let timeoutMs = 60_000

    private let exec: Exec

    public init(exec: @escaping Exec) {
        self.exec = exec
        machineID = nil
    }

    /// The route of Cloud machine `machineID`, whose commands run through the Cloud API's exec.
    public init(api: CloudAPIClient, machineID: String) {
        exec = { try await api.exec(machineID, command: $0, timeoutMs: $1) }
        self.machineID = machineID
    }

    /// The machine ``init(api:machineID:)`` named; a ``prepare(_:)`` refusal retries on it.
    private let machineID: String?

    /// A Cloud start's machine before its first chat: its agents reach models through its edge, and it serves
    /// what the start needs (`serves`: the daemon's capabilities). The machine is checked first and updated
    /// (`update`, ``afterUpdate(within:_:)``) only when it lacks one of them: a machine whose host updater follows
    /// its channel never takes this app's build when it is older (a DEV build of a branch), and an unconditional
    /// update held every start for 8 minutes before going on as it was (2026-11-16). A refusal is the start's
    /// failure, its reason as the start card shows it, with a retry on the same machine.
    ///
    /// A machine whose software predates the report (``Verdict/unsupported``) is not refused: the app's update
    /// never moves a machine back, so a machine on a newer build than this app's that still lacks the report
    /// (an image ahead of a DEV build's branch), or an app with no machine build to install, could never pass
    /// and every start on a new machine ended here. Its chat starts on the software the image came with; a
    /// machine that does report and is not routed is still refused. A capability the start then lacks ends it
    /// where it is used (``CloudOutdatedMachine/requireCapability(holds:lacks:relink:within:update:missing:)``, ``tooOld``).
    public func prepare(serves: @MainActor () -> Bool = { true }, _ update: @escaping @Sendable () async -> Void) async throws {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
        if await serves(), let verdict = try? await routeVerdict(), verdict == .ready || verdict == .unsupported {
            logger.info("cloud start chat: \(machineID ?? "", privacy: .public) already serves this start (\(verdict.rawValue, privacy: .public)); no update")
            return
        }
        logger.info("cloud start chat: bringing \(machineID ?? "", privacy: .public) to this app's machine software")
        do {
            try await afterUpdate(update)
        } catch let refused as Refused {
            if refused.verdict == .unsupported {
                logger.info("cloud start chat: \(machineID ?? "", privacy: .public) has no model-route report after its update, or the update did not end in time; starting on its own software")
                return
            }
            throw CloudMoveFailure(message: refused.message, retry: machineID.map { .move(machineID: $0) })
        }
    }

    private struct Request: Encodable { var stdout: String? }
    private struct Reply: Decodable { var command: String, verdict: Verdict? }

    /// How long a start waits for its machine to run the app's own machine software (the update pushes the
    /// app's pinned build and restarts the machine's services on it) before it gives up with ``Refused``:
    /// ``CloudOutdatedMachine/startUpdateWait``, which says why (it was 8 minutes until 2026-11-16).
    public static let updateDeadline: Duration = CloudOutdatedMachine.startUpdateWait

    /// Runs `update` (the app's update of the machine to its own machine software, a no-op for a machine
    /// already on it or on a newer build), at most `deadline`, then ``verify()``. A missed deadline is
    /// ``Refused`` with ``Verdict/unsupported``.
    public func afterUpdate(within deadline: Duration = updateDeadline, _ update: @escaping @Sendable () async -> Void) async throws {
        guard await CloudOutdatedMachine.bounded(deadline, clock: ContinuousClock(), { await update() }) != nil else {
            throw Refused(verdict: .unsupported)
        }
        try await verify()
    }

    /// Returns when the machine's agents reach models through its edge; throws ``Refused`` otherwise. An
    /// exec that fails (the machine went away, the route timed out) throws its own error.
    public func verify() async throws {
        let verdict = try await routeVerdict()
        guard verdict == .ready else { throw Refused(verdict: verdict) }
    }

    /// What Rust answers about the machine's model-route report (``verify()``'s reading). An exec that fails throws.
    func routeVerdict() async throws -> Verdict {
        guard let command = CloudStartCore().call("cloud_machine_route", Request(stdout: nil), as: Reply.self)?.command else { return .invalid }
        let ran = try await exec(command, Self.timeoutMs)
        return CloudStartCore().call("cloud_machine_route", Request(stdout: ran.stdout), as: Reply.self)?.verdict ?? .invalid
    }

    /// A start whose machine's software lacks a capability it needs (a chosen model connection's start credentials)
    /// and that the machine could not be updated to: its start card's text, with Retry on the same machine.
    public nonisolated static var tooOld: String {
        String(localized: "cloud.machineRoute.tooOld",
               defaultValue: "This Cloud machine's software is too old for this cmux and couldn't be updated. Try again in a few minutes, or update cmux.",
               table: "Cloud", bundle: .module)
    }

    nonisolated static func message(_ verdict: Verdict) -> String {
        switch verdict {
        case .ready:
            ""
        case .unsupported, .invalid:
            String(localized: "cloud.machineRoute.outdated",
                   defaultValue: "This Cloud machine's software couldn't be updated to match this app, so its agents can't reach models. Try again, or use a new machine.",
                   table: "Cloud", bundle: .module)
        case .noDaemon:
            String(localized: "cloud.machineRoute.noDaemon",
                   defaultValue: "The agent service on this Cloud machine didn't start. Try again in a moment.",
                   table: "Cloud", bundle: .module)
        case .holdsCredential:
            String(localized: "cloud.machineRoute.holdsCredential",
                   defaultValue: "This Cloud machine holds its own provider sign-in, so its agents skip the Cloud service's model route. Start the chat on a new machine.",
                   table: "Cloud", bundle: .module)
        case .notEdge:
            String(localized: "cloud.machineRoute.notEdge",
                   defaultValue: "This Cloud machine's agents aren't routed through the Cloud service yet. Try again, or start the chat on a new machine.",
                   table: "Cloud", bundle: .module)
        }
    }
}
