import Foundation

struct CmuxTaskManagerSnapshot {
    static let empty = CmuxTaskManagerSnapshot(
        rows: [],
        agentRows: [],
        aggregateRows: [],
        childMemoryRows: [],
        total: .zero,
        sampledAt: nil,
        memoryDiagnostic: nil
    )

    let rows: [CmuxTaskManagerRow]
    let agentRows: [CmuxTaskManagerRow]
    let aggregateRows: [CmuxTaskManagerRow]
    let childMemoryRows: [CmuxTaskManagerRow]
    let total: CmuxTaskManagerResources
    let sampledAt: Date?
    let memoryDiagnostic: CmuxTaskManagerMemoryDiagnostic?

    var hasLoadedResourceUsage: Bool {
        sampledAt != nil
            || !rows.isEmpty
            || !agentRows.isEmpty
            || !aggregateRows.isEmpty
            || !childMemoryRows.isEmpty
            || memoryDiagnostic != nil
    }

    var updatedText: String {
        guard let sampledAt else {
            return String(localized: "taskManager.updated.never", defaultValue: "Never")
        }
        return CmuxTaskManagerFormat.time(sampledAt)
    }

    init(
        rows: [CmuxTaskManagerRow],
        agentRows: [CmuxTaskManagerRow] = [],
        aggregateRows: [CmuxTaskManagerRow],
        childMemoryRows: [CmuxTaskManagerRow] = [],
        total: CmuxTaskManagerResources,
        sampledAt: Date?,
        memoryDiagnostic: CmuxTaskManagerMemoryDiagnostic? = nil
    ) {
        self.rows = rows
        self.agentRows = agentRows
        self.aggregateRows = aggregateRows
        self.childMemoryRows = childMemoryRows
        self.total = total
        self.sampledAt = sampledAt
        self.memoryDiagnostic = memoryDiagnostic
    }

    init(
        rows: [CmuxTaskManagerRow],
        agentRows: [CmuxTaskManagerRow] = [],
        total: CmuxTaskManagerResources,
        sampledAt: Date?,
        memoryDiagnostic: CmuxTaskManagerMemoryDiagnostic? = nil,
        agentAssetResolver: SessionAgentAssetResolver = .standard
    ) {
        self.init(
            rows: rows,
            agentRows: agentRows,
            aggregateRows: CmuxTaskManagerSnapshotDecoder.programAggregateRows(from: rows, agentAssetResolver: agentAssetResolver),
            childMemoryRows: CmuxTaskManagerSnapshotDecoder.childMemoryRows(from: memoryDiagnostic, agentAssetResolver: agentAssetResolver),
            total: total,
            sampledAt: sampledAt,
            memoryDiagnostic: memoryDiagnostic
        )
    }

    init(
        payload: [String: Any],
        agentAssetResolver: SessionAgentAssetResolver = .standard
    ) {
        self = CmuxTaskManagerSnapshotDecoder(
            payload: payload,
            agentAssetResolver: agentAssetResolver
        ).decode()
    }
}
