/// Bounded counts of the native Iroh paths currently visible to a connection.
struct CmxIrohConnectionPathCounts: Equatable, Sendable {
    /// Maximum number of paths represented in one diagnostic snapshot.
    static let maximumReportedPathCount = 64

    let relay: Int
    let nonRelay: Int

    static let zero = Self(relay: 0, nonRelay: 0)

    init(snapshots: [CmxIrohConnectionPathSnapshot]) {
        var relay = 0
        var nonRelay = 0
        for snapshot in snapshots.prefix(Self.maximumReportedPathCount) {
            if snapshot.isRelay {
                relay += 1
            } else {
                nonRelay += 1
            }
        }
        self.relay = relay
        self.nonRelay = nonRelay
    }

    init(relay: Int, nonRelay: Int) {
        let boundedRelay = max(0, min(relay, Self.maximumReportedPathCount))
        self.relay = boundedRelay
        self.nonRelay = max(
            0,
            min(nonRelay, Self.maximumReportedPathCount - boundedRelay)
        )
    }

    var total: Int { relay + nonRelay }
}
