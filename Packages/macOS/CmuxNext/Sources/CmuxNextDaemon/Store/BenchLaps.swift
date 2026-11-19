import Foundation

/// Bench-only ref (never in a PR): per-phase laps of one `DaemonStore.intend`, for the overlay bench's breakdown.
/// The store holds one only while the bench sets it (``DaemonStore/benchLaps``); each lap adds the time since the
/// previous lap to its phase.
@MainActor final class BenchLaps {
    private(set) var laps: [String: UInt64] = [:]
    private var last: UInt64 = 0

    func start() {
        laps.removeAll(keepingCapacity: true)
        last = DispatchTime.now().uptimeNanoseconds
    }

    func lap(_ phase: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        laps[phase, default: 0] += now - last
        last = DispatchTime.now().uptimeNanoseconds
    }
}
