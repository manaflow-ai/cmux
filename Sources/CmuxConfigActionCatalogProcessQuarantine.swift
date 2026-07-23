import Foundation

actor CmuxConfigActionCatalogProcessQuarantine {
    static let shared = CmuxConfigActionCatalogProcessQuarantine(
        generalCapacity: 4,
        globalCapacity: 2
    )

    private let generalCapacity: Int
    private let globalCapacity: Int
    private let recordsReleaseAttempts: Bool
    private var entries: [UUID: CmuxConfigActionCatalogProcessQuarantineEntry] = [:]
    private var releaseAttemptCounts: [UUID: Int] = [:]

    init(
        generalCapacity: Int,
        globalCapacity: Int,
        recordsReleaseAttempts: Bool = false
    ) {
        precondition(generalCapacity > 0)
        precondition(globalCapacity > 0)
        self.generalCapacity = generalCapacity
        self.globalCapacity = globalCapacity
        self.recordsReleaseAttempts = recordsReleaseAttempts
    }

    func reserve(
        key: String,
        lane: CmuxConfigActionCatalogProcessQuarantineLane
    ) -> CmuxConfigActionCatalogProcessQuarantineLease? {
        let laneEntryCount = entries.values.lazy.filter { $0.lane == lane }.count
        let laneCapacity = lane == .global ? globalCapacity : generalCapacity
        guard laneEntryCount < laneCapacity,
              !entries.values.contains(where: { $0.key == key && $0.owner != nil }) else {
            return nil
        }
        let lease = CmuxConfigActionCatalogProcessQuarantineLease(
            id: UUID(),
            key: key,
            lane: lane
        )
        entries[lease.id] = CmuxConfigActionCatalogProcessQuarantineEntry(
            key: key,
            lane: lane,
            owner: nil
        )
        return lease
    }

    func quarantine(
        lease: CmuxConfigActionCatalogProcessQuarantineLease,
        owner: any CmuxConfigActionCatalogQuarantinedProcess
    ) -> Bool {
        guard var entry = entries[lease.id],
              entry.key == lease.key,
              entry.lane == lease.lane,
              entry.owner == nil else {
            return false
        }
        entry.owner = owner
        entries[lease.id] = entry
        return true
    }

    func release(_ lease: CmuxConfigActionCatalogProcessQuarantineLease) {
        if recordsReleaseAttempts {
            releaseAttemptCounts[lease.id, default: 0] += 1
        }
        let removed = entries.removeValue(forKey: lease.id)
        assert(removed != nil, "action catalog quarantine lease released more than once")
    }

    func releaseAttemptCount(
        for lease: CmuxConfigActionCatalogProcessQuarantineLease
    ) -> Int {
        releaseAttemptCounts[lease.id, default: 0]
    }

    func state() -> CmuxConfigActionCatalogProcessQuarantineState {
        let general = entries.values.filter { $0.lane == .general }
        let global = entries.values.filter { $0.lane == .global }
        let generalQuarantined = general.filter { $0.owner != nil }
        let globalQuarantined = global.filter { $0.owner != nil }
        return CmuxConfigActionCatalogProcessQuarantineState(
            generalReservedCount: general.count - generalQuarantined.count,
            generalQuarantinedCount: generalQuarantined.count,
            globalReservedCount: global.count - globalQuarantined.count,
            globalQuarantinedCount: globalQuarantined.count,
            blockedKeys: Set((generalQuarantined + globalQuarantined).map(\.key))
        )
    }
}
