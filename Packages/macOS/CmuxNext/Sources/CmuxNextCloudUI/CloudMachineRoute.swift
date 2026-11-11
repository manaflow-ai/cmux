public import CmuxNextCloud
import Foundation

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
    }

    private struct Request: Encodable { var stdout: String? }
    private struct Reply: Decodable { var command: String, verdict: Verdict? }

    /// How long a start waits for its machine to run the app's own machine software (the update pushes the
    /// app's pinned build and restarts the machine's services on it) before it gives up with ``Refused``.
    public static let updateDeadline: Duration = .seconds(8 * 60)

    /// Runs `update` (the app's update of the machine to its own machine software, a no-op for a machine
    /// already on it or on a newer build), at most `deadline`, then ``verify()``. A missed deadline is
    /// ``Refused`` with ``Verdict/unsupported``.
    public func afterUpdate(within deadline: Duration = updateDeadline, _ update: @escaping @Sendable () async -> Void) async throws {
        do {
            try await withDeadline(deadline, label: "cloud machine software update") { await update() }
        } catch is DeadlineExceeded {
            throw Refused(verdict: .unsupported)
        }
        try await verify()
    }

    /// Returns when the machine's agents reach models through its edge; throws ``Refused`` otherwise. An
    /// exec that fails (the machine went away, the route timed out) throws its own error.
    public func verify() async throws {
        guard let command = CloudStartCore().call("cloud_machine_route", Request(stdout: nil), as: Reply.self)?.command else {
            throw Refused(verdict: .invalid)
        }
        let ran = try await exec(command, Self.timeoutMs)
        let verdict = CloudStartCore().call("cloud_machine_route", Request(stdout: ran.stdout), as: Reply.self)?.verdict ?? .invalid
        guard verdict == .ready else { throw Refused(verdict: verdict) }
    }

    static func message(_ verdict: Verdict) -> String {
        switch verdict {
        case .ready:
            ""
        case .unsupported, .invalid:
            String(localized: "cloud.machineRoute.outdated",
                   defaultValue: "This Cloud machine's software could not be updated to match this app, so its agents can't reach models yet. Try again, or start the chat on a new machine.",
                   table: "Cloud", bundle: .module)
        case .noDaemon:
            String(localized: "cloud.machineRoute.noDaemon",
                   defaultValue: "The agent service on this Cloud machine didn't start. Try again in a moment.",
                   table: "Cloud", bundle: .module)
        case .holdsCredential:
            String(localized: "cloud.machineRoute.holdsCredential",
                   defaultValue: "This Cloud machine holds its own provider sign-in, so its agents would not use the Cloud service's model route. Start the chat on a new machine.",
                   table: "Cloud", bundle: .module)
        case .notEdge:
            String(localized: "cloud.machineRoute.notEdge",
                   defaultValue: "This Cloud machine's agents aren't routed through the Cloud service yet. Try again, or start the chat on a new machine.",
                   table: "Cloud", bundle: .module)
        }
    }
}
