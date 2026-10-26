import Foundation
public import Observation

/// The latest update state of each ``DaemonUpdateTarget``, as ``DaemonUpdatePolicy`` reports it:
/// an ssh machine's sidebar tooltip shows its line (``detail(sshHost:)``), another surface looks a
/// target up by id (``detail(id:)``).
@MainActor @Observable
public final class DaemonUpdateBoard {
    // lint:allow one board per app process: the policy writes it, the sidebar of every window reads it
    public static let shared = DaemonUpdateBoard()

    /// The latest event per target id.
    public private(set) var targets: [String: DaemonUpdateEvent] = [:]

    public init() {}

    public func apply(_ event: DaemonUpdateEvent) {
        guard event.state != .cleared else {
            targets[event.id] = nil
            return
        }
        targets[event.id] = event
    }

    /// The tooltip line of target `id`, nil when it has no update state.
    public func detail(id: String) -> String? {
        targets[id].map { Self.line($0.state) }
    }

    /// The tooltip line of the ssh machine `host` (`SSHDestination.host`), nil when no target of
    /// that host has an update state. O(targets): a handful of machines.
    public func detail(sshHost host: String) -> String? {
        let host = host.lowercased()
        return targets.values.sorted { $0.id < $1.id }
            .first { $0.sshHost?.lowercased() == host }
            .map { Self.line($0.state) }
    }

    public nonisolated static func line(_ state: DaemonUpdateEvent.State) -> String {
        switch state {
        case .updating:
            String(localized: "agentPane.daemonUpdate.updating", defaultValue: "Updating to this Mac's build…", bundle: .module)
        case .retrying:
            String(localized: "agentPane.daemonUpdate.retrying", defaultValue: "Update will try again soon", bundle: .module)
        case .updated(let build):
            String(format: String(localized: "agentPane.daemonUpdate.updated", defaultValue: "Updated to %@", bundle: .module), build)
        case .failed(let reason, false):
            String(format: String(localized: "agentPane.daemonUpdate.failed", defaultValue: "Update failed: %@", bundle: .module), reason)
        case .failed(let reason, true):
            String(format: String(localized: "agentPane.daemonUpdate.rolledBack", defaultValue: "Update rolled back: %@", bundle: .module), reason)
        case .cleared:
            // Never on the board: `apply` drops the target.
            ""
        }
    }
}
