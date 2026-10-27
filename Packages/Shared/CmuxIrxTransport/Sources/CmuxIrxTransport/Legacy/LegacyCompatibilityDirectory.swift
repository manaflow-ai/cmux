import Foundation

/// Keeps older-client permission separate from v2 permission. A key once known
/// to belong to v2 never obtains permission through the older account list.
struct LegacyCompatibilityDirectory {
    /// The capability a v2 installation advertises in the older directory.
    static let v2Capability = "cmux.iroh-control.v2"

    private(set) var current: IrxDeviceListSnapshot?
    private var v2Endpoints = Set<String>()
    private var stopped = false

    mutating func apply(_ snapshot: IrxDeviceListSnapshot) {
        guard !stopped, current.map({ snapshot.rev > $0.rev }) ?? true else { return }
        for (endpoint, entry) in snapshot.entries
            where entry.capabilities?.contains(Self.v2Capability) == true {
            v2Endpoints.insert(endpoint)
        }
        var filtered = snapshot
        filtered.entries = snapshot.entries.filter { !v2Endpoints.contains($0.key) }
        current = filtered
    }

    mutating func excludeV2Endpoints(_ endpoints: Set<String>) {
        guard !stopped else { return }
        v2Endpoints.formUnion(endpoints)
        if var snapshot = current {
            snapshot.entries = snapshot.entries.filter { !v2Endpoints.contains($0.key) }
            current = snapshot
        }
    }

    mutating func restamp(revision: Int, issuedAt: Date, receivedAtWall: Date,
                         receivedAtMonotonic: ContinuousClock.Instant) {
        guard !stopped, let next = current?.restamped(rev: revision, issuedAt: issuedAt,
            receivedAtWall: receivedAtWall, receivedAtMonotonic: receivedAtMonotonic) else { return }
        current = next
    }

    mutating func stop() {
        stopped = true
        current = nil
    }
}
