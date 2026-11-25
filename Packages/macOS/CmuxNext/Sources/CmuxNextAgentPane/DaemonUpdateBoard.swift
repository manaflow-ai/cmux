import CmuxNextWakeups
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
    /// One quiet hold per machine that went offline (``QuietHold/connectionDelay``, 10 s): "offline;
    /// it will update when it's back" offers nothing to do, and a machine that drops for a reconnect
    /// or a daemon handoff is back well under it (Leo, 2026-11-14: "i also want all our connectivity
    /// stuff to shut up and load faster"). Meanwhile the board keeps what it drew before the drop.
    /// The stretch lasts through the policy's own retries (offline, updating, offline) and ends on
    /// any other state; a failure or a machine that cannot update (its Update button) shows at once.
    @ObservationIgnored private var offlineHolds: [String: QuietHold] = [:]
    /// The offline event of a machine whose hold still runs: drawn once it has lasted.
    @ObservationIgnored private var heldOffline: [String: DaemonUpdateEvent] = [:]
    private let offlineQuiet: Duration
    private let clock: any Clock<Duration>

    /// `offlineQuiet`: how long an offline machine says nothing, nil for the shared connection bound
    /// (tests pass `.zero` for the board as it was, with no hold). `clock`: the hold's clock.
    public init(offlineQuiet: Duration? = nil, clock: any Clock<Duration> = ContinuousClock()) {
        self.offlineQuiet = offlineQuiet ?? QuietHold.connectionDelay
        self.clock = clock
    }

    public func apply(_ event: DaemonUpdateEvent) {
        if event.state != .updating, event.state != .retrying { clicked.remove(event.id) }
        guard !holdsOffline(event) else { return }
        guard event.state != .cleared else {
            targets[event.id] = nil
            return
        }
        targets[event.id] = event
    }

    /// True while machine `id` is offline and its hold still runs: nothing says so yet.
    func offlineHeld(_ id: String) -> Bool {
        offlineHolds[id]?.held ?? false
    }

    /// Runs `event` through its machine's offline hold; true when the board keeps what it drew.
    private func holdsOffline(_ event: DaemonUpdateEvent) -> Bool {
        let id = event.id
        let offline = event.state == .offline
        let retry = event.state == .updating || event.state == .retrying
        guard offlineQuiet > .zero, offline || (retry && offlineHolds[id] != nil) else {
            offlineHolds.removeValue(forKey: id)?.update(false) {}
            heldOffline[id] = nil
            return false
        }
        guard offline else {
            // The policy's own retry of an offline machine: drawn, and the stretch goes on.
            heldOffline[id] = nil
            return false
        }
        let hold = offlineHolds[id] ?? QuietHold(owner: "daemon-update-offline", delay: offlineQuiet, clock: clock)
        offlineHolds[id] = hold
        heldOffline[id] = event
        hold.update(true) { [weak self] in
            guard let self, let held = heldOffline.removeValue(forKey: id) else { return }
            targets[id] = held
        }
        if !hold.held { heldOffline[id] = nil }
        return hold.held
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
        return (String(localized: "agentPane.daemonUpdate.machines.title", defaultValue: "Other machines", bundle: .localizedModule),
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
        String(localized: "agentPane.daemonUpdate.machines.update", defaultValue: "Update", bundle: .localizedModule)
    }

    /// Why an Update click did not run: the machine is gone from this run, or updates of other
    /// machines are off.
    public nonisolated static var updateRefused: String {
        String(localized: "agentPane.daemonUpdate.machines.updateRefused",
               defaultValue: "This machine can't be updated now. Try again once it's connected.", bundle: .localizedModule)
    }

    /// The row's "updating" line of machine `name`.
    nonisolated static func updatingLine(_ name: String) -> String {
        String(format: String(localized: "agentPane.daemonUpdate.machines.updating", defaultValue: "Updating %@ to this Mac's build…",
                              bundle: .localizedModule), name)
    }

    /// The row's line of machine `name` while it is offline.
    nonisolated static func offlineLine(_ name: String) -> String {
        String(format: String(localized: "agentPane.daemonUpdate.machines.offline", defaultValue: "%@ is offline; it will update when it's back",
                              bundle: .localizedModule), name)
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
            String(localized: "agentPane.daemonUpdate.updating", defaultValue: "Updating to this Mac's version…", bundle: .localizedModule)
        case .retrying:
            String(localized: "agentPane.daemonUpdate.retrying", defaultValue: "Update will try again soon", bundle: .localizedModule)
        case .offline:
            String(localized: "agentPane.daemonUpdate.offline", defaultValue: "Offline; it will update when it's back", bundle: .localizedModule)
        case .updated(let build):
            String(format: String(localized: "agentPane.daemonUpdate.updated", defaultValue: "Updated to %@", bundle: .localizedModule), build)
        case .kept(let kept):
            keptLine(kept)
        case .failed(let reason, _) where AcpmuxPeerUpdateReply.linkLost(reason):
            String(localized: "agentPane.daemonUpdate.noAnswer", defaultValue: "Didn't answer", bundle: .localizedModule)
        case .failed(let reason, false):
            String(format: String(localized: "agentPane.daemonUpdate.failed", defaultValue: "Update failed: %@", bundle: .localizedModule), reason)
        case .failed(let reason, true):
            String(format: String(localized: "agentPane.daemonUpdate.rolledBack", defaultValue: "Update rolled back: %@", bundle: .localizedModule), reason)
        case .cannotUpdate(let reason):
            reason
        case .cleared:
            // Never on the board: `apply` drops the target.
            ""
        }
    }

    /// The line of a machine that refused the build and kept its own: that it kept it, and why.
    /// Never "updated" (a host keeping a newer commit answers `current`, #43770).
    nonisolated static func keptLine(_ kept: DaemonUpdateOutcome.Kept) -> String {
        switch kept {
        case .newerInstalled:
            String(localized: "agentPane.daemonUpdate.kept.newerInstalled", defaultValue: "Kept its build: newer build installed", bundle: .localizedModule)
        case .ownBuild:
            String(localized: "agentPane.daemonUpdate.kept.ownBuild", defaultValue: "Kept its build: it runs a build with local changes",
                   bundle: .localizedModule)
        case .restartWindow(let next?):
            String(format: String(localized: "agentPane.daemonUpdate.kept.restartWindowUntil",
                                  defaultValue: "Kept its build: restarted recently; next update after %@ UTC", bundle: .localizedModule),
                   next)
        case .restartWindow(nil):
            String(localized: "agentPane.daemonUpdate.kept.restartWindow", defaultValue: "Kept its build: restarted recently",
                   bundle: .localizedModule)
        }
    }

    /// The row line of a failed or rolled-back update, in plain words; nil for any other state. A
    /// connection that dropped (ssh's "Connection to UNKNOWN port 65535 timed out" through a
    /// ProxyJump) reads "huge-blue didn't answer", never the raw ssh words.
    nonisolated static func notice(_ event: DaemonUpdateEvent) -> String? {
        guard case .failed(let reason, let rolledBack) = event.state else { return nil }
        if AcpmuxPeerUpdateReply.linkLost(reason) {
            return String(format: String(localized: "agentPane.daemonUpdate.notice.noAnswer", defaultValue: "%@ didn't answer",
                                         bundle: .localizedModule), event.displayName)
        }
        return rolledBack
            ? String(format: String(localized: "agentPane.daemonUpdate.notice.rolledBack",
                                    defaultValue: "%1$@ is still on its previous version: %2$@", bundle: .localizedModule), event.displayName, reason)
            : String(format: String(localized: "agentPane.daemonUpdate.notice.failed", defaultValue: "Couldn't update %1$@: %2$@",
                                    bundle: .localizedModule), event.displayName, reason)
    }
}
