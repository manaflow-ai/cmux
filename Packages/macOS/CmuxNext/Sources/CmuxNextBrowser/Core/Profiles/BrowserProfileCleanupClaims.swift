import Foundation

/// The deleted profiles whose engine data is being removed now (SW-08, #30757). An in-flight
/// deletion owns its id until both engines' data is gone, so a second cleanup task never runs for
/// it and never races a later re-creation. The App keeps one in memory; it is never saved, since
/// a new launch has no cleanup in flight.
public nonisolated struct BrowserProfileCleanupClaims: Sendable, Equatable {
    public private(set) var inFlight: Set<String> = []

    public init() {}

    /// Claims and returns the ids of `pending` that no cleanup runs for yet and whose store no
    /// engine opened in this process (`isOpen`: Chromium and WebKit keep an opened store's files
    /// until the process ends, so those wait for the next launch).
    public mutating func claim(_ pending: [String], isOpen: (BrowserProfileID) -> Bool) -> [String] {
        let ready = pending.filter { id in
            guard !inFlight.contains(id) else { return false }
            guard let profile = BrowserProfileRecord.engineProfile(for: id) else { return true }
            return !isOpen(profile)
        }
        inFlight.formUnion(ready)
        return ready
    }

    /// The cleanup of `ids` ended, whether it removed their data or not; a later pass may claim them again.
    public mutating func release(_ ids: [String]) {
        inFlight.subtract(ids)
    }
}
