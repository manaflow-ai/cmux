import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// New dev servers on an own machine (joined by sign-in, or over ssh), offered in its chats the way a
/// Cloud machine's are (Leo 2026-11-23: "Own machines as good as Cloud ... see a new dev server's port").
///
/// A Cloud machine's ports arrive on the Cloud wire (``CloudPortChange``); an own machine has no such
/// wire, so while a chat of that machine is open the watch asks the machine's own daemon for its
/// listeners (`machine-listening-tcp`) every ``interval``. Which ports count is the daemon's rule
/// (cmux-tui-core `machine_ports.rs`); a daemon before that rule offers nothing. The first read of a
/// machine is its baseline (`known`): only a port that opens after it shows the chat's Open app card,
/// whose click opens `localhost:PORT` in a tab beside the chat, which reaches that machine's
/// localhost (remote localhost, `loopback-forward-v1`).
@MainActor
final class OwnMachinePortWatch {
    static let interval: Duration = .seconds(3)

    /// The own machines (not Cloud, not this Mac) with a chat open now, by machine id.
    var machines: @MainActor () -> [String: DaemonService] = { [:] }
    /// A port opened or closed on `machineID`.
    var deliver: @MainActor (CloudPortChange) -> Void = { _ in }

    private var known: [String: Set<Int>] = [:]
    private var loop: Task<Void, Never>?

    /// Starts the watch once; it reads nothing while no own machine has a chat open.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pass()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// The card's Open on an own machine's chat: `localhost:PORT` as a link clicked in the chat, in a
    /// tab beside it, whose localhost is the chat's machine.
    static func open(_ port: Int, from model: AgentPaneModel) -> Bool {
        guard (1...65535).contains(port), let url = URL(string: "http://localhost:\(port)/") else { return false }
        return model.onOpenPreview?(url) ?? false
    }

    private func pass() async {
        let machines = machines()
        // A machine with no chat open any more starts over: its next read is a baseline again.
        for gone in known.keys where machines[gone] == nil { known[gone] = nil }
        for (machineID, daemon) in machines {
            guard let connection = daemon.connection,
                  let listeners = try? await connection.request(MachineListeningTCPRequest()).ports else { continue }
            for change in Self.changes(machineID: machineID, before: known[machineID], now: listeners) { deliver(change) }
            known[machineID] = Set(listeners.map(\.port))
        }
    }

    /// What `now` changed since `before` (nil: the first read, every port `known`).
    nonisolated static func changes(machineID: String, before: Set<Int>?, now: [MachineListeningTCPRequest.Listener]) -> [CloudPortChange] {
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
