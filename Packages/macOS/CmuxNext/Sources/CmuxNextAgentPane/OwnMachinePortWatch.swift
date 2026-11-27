public import CmuxNextCloud
public import CmuxNextDaemon
public import Foundation
import CmuxNextWakeups

/// New dev servers on an own machine (joined by sign-in, or over ssh), offered in its chats the way a
/// Cloud machine's are (Leo 2026-11-23: "Own machines as good as Cloud ... see a new dev server's port").
///
/// A Cloud machine's ports arrive on the Cloud wire (``CloudPortChange``, ``CloudMachineWire``); an own
/// machine has no such wire, so while a chat of that machine is open the watch asks the machine's own
/// daemon for its listeners (`machine-listening-tcp`) every ``interval``. Which ports count is the
/// daemon's rule (cmux-tui-core `machine_ports.rs`); a daemon before that rule offers nothing. The first
/// read of a machine is its baseline (`known`): only a port that opens after it shows the chat's Open
/// app card. With no own machine's chat open the watch schedules nothing; showing such a chat
/// (``poke()``) starts it again.
@MainActor
public final class OwnMachinePortWatch {
    public static let interval: Duration = .seconds(3)

    /// The own machines (not Cloud, not this Mac) with a chat open now, by machine id (repeats allowed).
    private var machineIDs: @MainActor () -> [String] = { [] }
    /// A machine's daemon link, nil while it has none.
    private var daemon: @MainActor (String) -> DaemonConnection? = { _ in nil }
    /// A port opened or closed on its machine.
    private var deliver: @MainActor (CloudPortChange) -> Void = { _ in }

    private var known: [String: Set<Int>] = [:]
    private var reading = false
    private let timer = DemandTimer(owner: "ownMachinePorts.pass")

    public init() {}

    public func wire(deliver: @escaping @MainActor (CloudPortChange) -> Void, machineIDs: @escaping @MainActor () -> [String], daemon: @escaping @MainActor (String) -> DaemonConnection?) {
        self.deliver = deliver
        self.machineIDs = machineIDs
        self.daemon = daemon
    }

    /// A chat of an own machine was shown: reads now if the watch had stopped.
    public func poke() {
        guard !reading, !timer.isScheduled else { return }
        timer.schedule(after: .zero) { [weak self] in await self?.pass() }
    }

    private func pass() async {
        var machines: [String: DaemonConnection] = [:]
        for id in machineIDs() where machines[id] == nil { machines[id] = daemon(id) }
        // A machine with no chat open any more starts over: its next read is a baseline again.
        for gone in known.keys where machines[gone] == nil { known[gone] = nil }
        guard !machines.isEmpty else { return }
        reading = true
        for (machineID, connection) in machines {
            guard let listeners = try? await connection.request(MachineListeningTCPRequest()).ports else { continue }
            for change in Self.changes(machineID: machineID, before: known[machineID], now: listeners) { deliver(change) }
            known[machineID] = Set(listeners.map(\.port))
        }
        reading = false
        timer.schedule(after: Self.interval) { [weak self] in await self?.pass() }
    }

    /// What `now` changed since `before` (nil: the first read, every port `known`).
    public nonisolated static func changes(machineID: String, before: Set<Int>?, now: [MachineListeningTCPRequest.Listener]) -> [CloudPortChange] {
        let ports = Set(now.map(\.port))
        var changes = now.filter { before?.contains($0.port) != true }.map {
            CloudPortChange(machineID: machineID, port: $0.port, proto: "tcp", process: $0.process, state: .opened, known: before == nil)
        }
        for closed in (before ?? []).subtracting(ports).sorted() {
            changes.append(CloudPortChange(machineID: machineID, port: closed, proto: "tcp", process: nil, state: .closed))
        }
        return changes
    }
}
