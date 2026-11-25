import CmuxNextDesign
import CmuxNextWakeups

/// A peer's automatic reconnect keeps its last rows until the shared quiet bound.
/// Transport state stays immediate; only its presentation waits, with one timer per down peer.
@MainActor
final class RemoteMachinesConnectionPresentation {
    private let clock: any Clock<Duration>
    private var holds: [String: QuietHold] = [:]
    private var cached: [String: RemoteMachinesSidebar.Machine] = [:]

    init(clock: any Clock<Duration> = ContinuousClock()) { self.clock = clock }

    func update(_ machines: [RemoteMachinesSidebar.Machine],
                onChange: @escaping @MainActor () -> Void) -> [RemoteMachinesSidebar.Machine] {
        let down = Set(machines.filter { !$0.online }.map(\.peer))
        for peer in Array(holds.keys) where !down.contains(peer) {
            holds.removeValue(forKey: peer)?.update(false, onShow: {})
        }
        let next = machines.map { machine in
            guard !machine.online else { return machine }
            let hold = holds[machine.peer] ?? QuietHold(owner: "sidebar.remoteMachines.connection",
                                                       delay: NoticeTiming.connectionQuiet, clock: clock)
            holds[machine.peer] = hold
            hold.update(true, onShow: onChange)
            guard hold.held else { return machine }
            if let previous = cached[machine.peer] { return previous }
            // A newly discovered peer has no saved rows: show its name without a connection notice.
            var quiet = machine
            quiet.online = true
            return quiet
        }.sorted { ($0.online ? 0 : 1, $0.peer) < ($1.online ? 0 : 1, $1.peer) }
        cached = Dictionary(uniqueKeysWithValues: next.map { ($0.peer, $0) })
        return next
    }

    func stop() {
        for hold in holds.values { hold.update(false, onShow: {}) }
        holds = [:]
        cached = [:]
    }
}
