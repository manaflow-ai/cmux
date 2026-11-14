import Foundation
public import Observation

/// The latest update state of each ``DaemonUpdateTarget``, as ``DaemonUpdatePolicy`` reports it:
/// an ssh machine's sidebar tooltip shows its line (``detail(sshHost:)``), another surface looks a
/// target up by id (``detail(id:)``), and Settings > Updates lists the machines that cannot update,
/// are offline or failed to, in one row (``otherMachines``), each reason in plain words. No machine
/// update ever raises a toast: the policy retries a failure in the background, and the row is the
/// only place one shows (Leo, 2026-11-06, on "huge-blue is still on its previous version ·
/// Connection to UNKNOWN port 65535 timed out" drawn over his message: "why is this still happening
/// yo"; before: "i dont like chatty unactionable toasts"). The app has one
/// (``DaemonUpdates/board``, made once by `AppServices`): the policy writes it, the sidebar of every
/// window and Settings read it.
@MainActor @Observable
public final class DaemonUpdateBoard {
    /// The latest event per target id.
    public private(set) var targets: [String: DaemonUpdateEvent] = [:]
    /// Machines whose Update the person clicked (``update(_:retry:)``), until their update ends.
    private var clicked: Set<String> = []

    public init() {}

    public func apply(_ event: DaemonUpdateEvent) {
        if event.state != .updating, event.state != .retrying { clicked.remove(event.id) }
        guard event.state != .cleared else {
            targets[event.id] = nil
            return
        }
        targets[event.id] = event
    }

    /// Settings > Updates' row of other machines: each that cannot update in place, then each whose
    /// update failed, as one line each; nil when none. Read when the card shows, and watched while
    /// it shows (`cmux.settings.channels.machines.changed`).
    ///
    /// A machine that cannot update in place has an Update button (``OtherMachine/canUpdate``,
    /// the policy's ``DaemonUpdatePolicy/retry(_:)``). Once clicked, its line says it is updating
    /// until the update ends: updated, it leaves the row; still unable or failed, its line returns.
    public var otherMachines: (title: String, lines: [String], machines: [OtherMachine])? {
        let events = targets.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        var machines: [OtherMachine] = []
        for event in events {
            switch event.state {
            case .cannotUpdate(let reason):
                machines.append(OtherMachine(id: event.id, line: reason, canUpdate: true))
            case .offline:
                machines.append(OtherMachine(id: event.id, line: Self.offlineLine(event.displayName), canUpdate: false))
            case .updating where clicked.contains(event.id), .retrying where clicked.contains(event.id):
                machines.append(OtherMachine(id: event.id, line: Self.updatingLine(event.displayName), canUpdate: false))
            default:
                break
            }
        }
        machines += events.compactMap { event in Self.notice(event).map { OtherMachine(id: event.id, line: $0, canUpdate: false) } }
        guard !machines.isEmpty else { return nil }
        return (String(localized: "agentPane.daemonUpdate.machines.title", defaultValue: "Other machines", bundle: .module),
                machines.map(\.line), machines)
    }

    /// One line of ``otherMachines``: the machine's target id, its text, and whether it has an
    /// Update button.
    public struct OtherMachine: Sendable, Equatable {
        public var id: String
        public var line: String
        public var canUpdate: Bool
    }

    /// The person clicked Update on machine `id` (``otherMachines``): its line says it is updating
    /// while the policy runs it. False (and no change) when `retry` refused it.
    @discardableResult
    public func update(_ id: String, retry: (String) async -> Bool) async -> Bool {
        guard case .cannotUpdate = targets[id]?.state, await retry(id) else { return false }
        clicked.insert(id)
        return true
    }

    /// The Update button of a machine in ``otherMachines``.
    public nonisolated static var updateLabel: String {
        String(localized: "agentPane.daemonUpdate.machines.update", defaultValue: "Update", bundle: .module)
    }

    /// Why an Update click did not run: the machine is gone from this run, or updates of other
    /// machines are off.
    public nonisolated static var updateRefused: String {
        String(localized: "agentPane.daemonUpdate.machines.updateRefused",
               defaultValue: "This machine can't be updated now. Try again once it's connected.", bundle: .module)
    }

    /// The row's "updating" line of machine `name`.
    nonisolated static func updatingLine(_ name: String) -> String {
        String(format: String(localized: "agentPane.daemonUpdate.machines.updating", defaultValue: "Updating %@ to this Mac's build…",
                              bundle: .module), name)
    }

    /// The row's line of machine `name` while it is offline.
    nonisolated static func offlineLine(_ name: String) -> String {
        String(format: String(localized: "agentPane.daemonUpdate.machines.offline", defaultValue: "%@ is offline; it will update when it's back",
                              bundle: .module), name)
    }

    /// The tooltip line of target `id`, nil when it has no update state.
    public func detail(id: String) -> String? {
        targets[id].map { Self.line($0.state) }
    }

    /// The tooltip line of the ssh machine `host` (`SSHDestination.host`), nil when no target of
    /// that host has an update state. O(targets): a handful of machines.
    public func detail(sshHost host: String) -> String? {
        let host = host.lowercased()
        // One pass; of several targets on one host, the lowest id, so the line never flips between them.
        var match: DaemonUpdateEvent?
        for event in targets.values where event.sshHost?.lowercased() == host {
            if match.map({ event.id < $0.id }) ?? true { match = event }
        }
        return match.map { Self.line($0.state) }
    }

    public nonisolated static func line(_ state: DaemonUpdateEvent.State) -> String {
        switch state {
        case .updating:
            String(localized: "agentPane.daemonUpdate.updating", defaultValue: "Updating to this Mac's version…", bundle: .module)
        case .retrying:
            String(localized: "agentPane.daemonUpdate.retrying", defaultValue: "Update will try again soon", bundle: .module)
        case .offline:
            String(localized: "agentPane.daemonUpdate.offline", defaultValue: "Offline; it will update when it's back", bundle: .module)
        case .updated(let build):
            String(format: String(localized: "agentPane.daemonUpdate.updated", defaultValue: "Updated to %@", bundle: .module), build)
        case .failed(let reason, _) where AcpmuxPeerUpdateReply.linkLost(reason):
            String(localized: "agentPane.daemonUpdate.noAnswer", defaultValue: "Didn't answer", bundle: .module)
        case .failed(let reason, false):
            String(format: String(localized: "agentPane.daemonUpdate.failed", defaultValue: "Update failed: %@", bundle: .module), reason)
        case .failed(let reason, true):
            String(format: String(localized: "agentPane.daemonUpdate.rolledBack", defaultValue: "Update rolled back: %@", bundle: .module), reason)
        case .cannotUpdate(let reason):
            reason
        case .cleared:
            // Never on the board: `apply` drops the target.
            ""
        }
    }

    /// The row line of a failed or rolled-back update, in plain words; nil for any other state. A
    /// connection that dropped (ssh's "Connection to UNKNOWN port 65535 timed out" through a
    /// ProxyJump) reads "huge-blue didn't answer", never the raw ssh words.
    nonisolated static func notice(_ event: DaemonUpdateEvent) -> String? {
        guard case .failed(let reason, let rolledBack) = event.state else { return nil }
        if AcpmuxPeerUpdateReply.linkLost(reason) {
            return String(format: String(localized: "agentPane.daemonUpdate.notice.noAnswer", defaultValue: "%@ didn't answer",
                                         bundle: .module), event.displayName)
        }
        return rolledBack
            ? String(format: String(localized: "agentPane.daemonUpdate.notice.rolledBack",
                                    defaultValue: "%1$@ is still on its previous version: %2$@", bundle: .module), event.displayName, reason)
            : String(format: String(localized: "agentPane.daemonUpdate.notice.failed", defaultValue: "Couldn't update %1$@: %2$@",
                                    bundle: .module), event.displayName, reason)
    }
}
