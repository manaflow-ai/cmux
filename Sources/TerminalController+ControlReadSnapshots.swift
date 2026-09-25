import CmuxControlSocket
import Foundation

/// Main-actor publication of the read-side control-plane mirror.
///
/// The publisher deliberately builds a small, stable set of topology reads
/// (without request ids) and swaps one immutable package snapshot. Socket
/// workers can then answer repeated list/tree polls without entering the main
/// actor; a mutation schedules one coalesced refresh on the next actor turn.
extension TerminalController {
    func scheduleSocketReadSnapshotRefresh() {
        guard socketReadSnapshotRefreshTask == nil else { return }
        socketReadSnapshotRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.publishSocketReadSnapshot()
            self.socketReadSnapshotRefreshTask = nil
        }
    }

    /// Reopens opaque-handle discovery after a topology notification.
    func invalidateSocketHandleTopologyRefresh() {
        controlCommandCoordinator.invalidateHandleTopologyRefresh()
    }

    private func publishSocketReadSnapshot() {
        let requests: [ControlRequest] = [
            ControlRequest(id: nil, method: "window.list", params: [:]),
            ControlRequest(id: nil, method: "window.current", params: [:]),
            ControlRequest(id: nil, method: "window.displays", params: [:]),
            ControlRequest(id: nil, method: "workspace.list", params: [:]),
            ControlRequest(id: nil, method: "workspace.current", params: [:]),
            ControlRequest(id: nil, method: "surface.list", params: [:]),
            ControlRequest(id: nil, method: "surface.current", params: [:]),
            ControlRequest(id: nil, method: "pane.list", params: [:]),
            ControlRequest(id: nil, method: "pane.surfaces", params: [:]),
            ControlRequest(id: nil, method: "system.identify", params: [:]),
            ControlRequest(id: nil, method: "system.tree", params: [:]),
        ]
        var responses: [String: ControlCallResult] = [:]
        responses.reserveCapacity(requests.count)
        for request in requests {
            guard let result = controlCommandCoordinator.handleSocketWorkerV2(
                request,
                context: self
            ) else { continue }
            responses[ControlReadSnapshot.key(method: request.method, params: request.params)] = result
        }

        let nextGeneration = socketReadSnapshotStore.read().generation &+ 1
        socketReadSnapshotStore.publish(
            ControlReadSnapshot(generation: nextGeneration, responses: responses)
        )
        controlCommandCoordinator.markHandleTopologyRefreshCompleted()
    }
}

/// Persists the next available ranges for short control-socket refs.
///
/// Pre-fix builds restarted every `kind:N` sequence at 1. A caller that kept
/// `surface:7` across an app restart could therefore target a completely
/// different surface when the new process minted its own `surface:7`.
///
/// This store reserves a disjoint ordinal block per handle kind before the
/// registry starts minting. The first upgraded launch begins well outside the
/// realistic legacy range; subsequent launches begin at the previously
/// reserved upper bound. If a process consumes its whole reservation, it
/// extends the reservation before the next ordinal can be used.
final class ControlHandleOrdinalDefaultsStore: @unchecked Sendable {
    static let defaultMigrationFloor = 1_000_000_000
    static let defaultReservationSize = 10_000
    static let keyPrefix = "cmux.controlHandleOrdinals.v1.nextStart."

    private let defaults: UserDefaults
    private let migrationFloor: Int
    private let reservationSize: Int
    private let lock = NSLock()
    private var reservedUpperBounds: [ControlHandleKind: Int] = [:]

    init(
        defaults: UserDefaults,
        migrationFloor: Int = defaultMigrationFloor,
        reservationSize: Int = defaultReservationSize
    ) {
        self.defaults = defaults
        self.migrationFloor = max(1, migrationFloor)
        self.reservationSize = max(1, reservationSize)
    }

    func makeRegistry() -> ControlHandleRegistry {
        let startingOrdinals = reserveInitialRanges()
        return ControlHandleRegistry(
            startingOrdinals: startingOrdinals
        ) { [self] kind, nextOrdinal in
            reserveMoreIfNeeded(kind: kind, nextOrdinal: nextOrdinal)
        }
    }

    private func reserveInitialRanges() -> [ControlHandleKind: Int] {
        lock.lock()
        defer { lock.unlock() }

        var startingOrdinals: [ControlHandleKind: Int] = [:]
        for kind in ControlHandleKind.allCases {
            let key = Self.defaultsKey(for: kind)
            let persisted = (defaults.object(forKey: key) as? NSNumber)?.intValue
            let start = max(migrationFloor, persisted ?? migrationFloor)
            let upperBound = advancedReservation(from: start)
            startingOrdinals[kind] = start
            reservedUpperBounds[kind] = upperBound
            defaults.set(upperBound, forKey: key)
        }
        return startingOrdinals
    }

    private func reserveMoreIfNeeded(
        kind: ControlHandleKind,
        nextOrdinal: Int
    ) {
        lock.lock()
        defer { lock.unlock() }

        var upperBound = reservedUpperBounds[kind] ?? max(migrationFloor, nextOrdinal)
        guard nextOrdinal >= upperBound else { return }

        while nextOrdinal >= upperBound {
            let advanced = advancedReservation(from: upperBound)
            guard advanced > upperBound else { break }
            upperBound = advanced
        }

        reservedUpperBounds[kind] = upperBound
        defaults.set(upperBound, forKey: Self.defaultsKey(for: kind))
    }

    private func advancedReservation(from value: Int) -> Int {
        let (advanced, overflow) = value.addingReportingOverflow(reservationSize)
        return overflow ? Int.max : advanced
    }

    private static func defaultsKey(for kind: ControlHandleKind) -> String {
        keyPrefix + kind.rawValue
    }
}

extension TerminalController {
    /// Installs the process's control-ref registry before any app topology can
    /// mint a short ref. UUID ids remain the durable cross-process identity;
    /// short refs now fail closed when carried across app restarts.
    @MainActor
    func prepareControlHandleRegistryForLaunch(
        defaults: UserDefaults = .standard
    ) {
        let store = ControlHandleOrdinalDefaultsStore(defaults: defaults)
        controlCommandCoordinator.handles = store.makeRegistry()
    }
}
