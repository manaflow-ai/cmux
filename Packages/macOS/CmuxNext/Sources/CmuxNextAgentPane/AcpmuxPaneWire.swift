public import Foundation

/// The byte path under ``AcpmuxPaneSocket`` when it is not the local acpmux WebSocket: the frames
/// the host already checked go out through ``send(_:completion:)``, and the frames that come back
/// (acpmux JSON-RPC text) go through the same inbound checks and queues as the WebSocket's.
public nonisolated protocol AcpmuxPaneWire: Sendable {
    /// Opens the path. `onFrame` gets each inbound frame in order; `onClose` once, when the path
    /// ends by itself (never after ``cancel(code:reason:)``).
    func open(onFrame: @escaping @Sendable (String) -> Void,
              onClose: @escaping @Sendable (_ code: Int, _ reason: String) -> Void) async throws
    /// Sends one outbound frame; `completion` gets false when the path failed.
    func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void)
    /// Ends the path (the host's decision).
    func cancel(code: Int, reason: String)
    /// Reads one image from a remote chat's owning host. Local socket wires have no such route.
    func loadRemoteImage(_ path: String) async throws -> Data
}

public extension AcpmuxPaneWire {
    func loadRemoteImage(_ path: String) async throws -> Data {
        throw AgentSessionRemoteError(code: "remote.unsupported", message: "remote media is unavailable")
    }
}

/// A chat whose acpmux runs on another machine: the host's socket for it is a wire this route
/// makes (``RemoteAcpmuxWire`` over the owning session daemon), not a WebSocket to a local port.
/// Compared by identity.
public nonisolated final class AgentPaneRemoteRoute: Sendable {
    /// The machine's name, for logs (never a secret).
    public let machine: String
    /// The keyed restart of the machine's acpmux, when the app can do one (cx-0q7o).
    public let approvals: AgentPaneRemoteApprovals?
    private let make: @Sendable () -> any AcpmuxPaneWire

    public init(machine: String, approvals: AgentPaneRemoteApprovals? = nil, make: @escaping @Sendable () -> any AcpmuxPaneWire) {
        self.machine = machine
        self.approvals = approvals
        self.make = make
    }

    /// A fresh wire for one connection (each reconnect gets its own).
    public func makeWire() -> any AcpmuxPaneWire { make() }
}

/// What a chat's machine offers when its acpmux holds no person key of this app (cx-0q7o): its
/// name for the pane's notice, and the keyed restart (nil on success, else what failed).
public nonisolated struct AgentPaneRemoteApprovals: Sendable {
    /// Why a keyed restart failed; the pane says it in the user's language.
    public enum Failure: Sendable, Equatable {
        /// The system had no randomness for a key or a nonce.
        case noRandomness
        /// The new daemon did not report a key (the daemon's last error line, when there is one).
        case daemonTookNoKey(String?)
        /// The daemon that answers does not hold this app's key.
        case keyNotHeld
        /// The machine's agent daemon is too old for a keyed start (a Cloud machine, cx-psxg).
        case daemonTooOld
        /// The machine is not running.
        case machineNotRunning
        /// The person does not alone own the machine, or it is a team machine: approvals from
        /// this app stay off there (cx-psxg).
        case notSingleOwner
        /// ssh, the Cloud service or the machine failed (its own message).
        case failed(String)
    }

    /// The machine id the app binds this machine's key to (`AcpmuxRemotePersonKeys`).
    public let machineID: String
    public let label: String
    public let restart: @Sendable () async -> Failure?
    /// Who decided that a keyed restart before a new chat loses nothing.
    public enum Preparation: Sendable, Equatable {
        /// That machine's cmux-tui answered `agent_session.needs_keyed_start` with
        /// `safe_to_restart` (cx-0w0jj): restart now.
        case daemonSaidSafe
        /// A cmux-tui without `agent-session-start-keyed-reason-v1`: the app reads the acpmux
        /// status itself (cx-oa6ah). Remove when the oldest supported cmux-tui has the capability.
        case checkStatus
    }

    /// The keyed restart before a new chat starts there, only when that machine's agent daemon
    /// runs no agent (none to hand off, cx-oa6ah): true when this app's key is then bound. A
    /// daemon with live agents is left as it is; its Allow then shows the restart notice, and only
    /// the person's click restarts it. Nil where the app cannot tell.
    public let prepare: (@Sendable (Preparation) async -> Bool)?

    public init(machineID: String, label: String, restart: @escaping @Sendable () async -> Failure?,
                prepare: (@Sendable (Preparation) async -> Bool)? = nil) {
        self.machineID = machineID
        self.label = label
        self.restart = restart
        self.prepare = prepare
    }
}

extension AcpmuxConnection {
    /// The connection of a chat on another machine: no URL, no token; the wire carries it.
    nonisolated public static func remote(_ route: AgentPaneRemoteRoute) -> AcpmuxConnection {
        var connection = AcpmuxConnection(url: URL(fileURLWithPath: "/"), dashboardToken: "", localAppToken: nil)
        connection.remote = route
        return connection
    }
}
