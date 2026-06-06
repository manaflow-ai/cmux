import Foundation
import Observation
import OSLog

private let closedItemHistoryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ClosedItemHistory"
)

@MainActor
@Observable
final class ClosedItemHistoryStore {
    static let defaultCapacity = 200
    static let shared = ClosedItemHistoryStore(
        capacity: defaultCapacity,
        fileURL: defaultHistoryFileURL()
    )

    private(set) var revision: UInt64 = 0
    /// The most recently reopened item, re-closable via redo. Cleared whenever a
    /// new close is recorded (any ``push(_:)``) so redo only applies immediately
    /// after an undo.
    private(set) var redoTarget: ReopenedItemRef? = nil
    /// The operation most recently restored (by undo or pane restore), so a redo
    /// can re-close that whole group. Cleared on any new close.
    private(set) var lastRestoredOperationId: UUID? = nil
    private var records: [ClosedItemHistoryRecord] = []
    /// In-memory map from a restored record's id to the live item it produced.
    /// Not persisted, so it is empty after relaunch, which is exactly the
    /// reset-on-launch behavior: nothing is marked restored after a fresh launch.
    private var restoredRefByRecordId: [UUID: ReopenedItemRef] = [:]
    /// Injected liveness check (set by AppDelegate at startup): is this restored
    /// target still a live panel/workspace/window? Single source of truth for
    /// "already restored", so restore-remaining and undo never duplicate a live item.
    var isTargetLive: ((ReopenedItemRef) -> Bool)?
    private let capacity: Int?
    private let fileURL: URL?
    private let persistsRecordsSynchronously: Bool
    private var didFinishPersistedRecordsLoad: Bool
    private var needsPersistenceAfterPersistedRecordsLoad = false
    private var shouldDiscardPersistedRecordsOnLoad = false
    private var pendingPersistedRecordMutations: [PendingPersistedRecordMutation] = []

    private enum PendingPersistedRecordMutation {
        case remapPanelWorkspaceIds(
            oldWorkspaceId: UUID,
            newWorkspaceId: UUID,
            panelIdMap: [UUID: UUID]
        )
        case remapPanelAnchorIds(oldPanelId: UUID, newPanelId: UUID)
        case remapWorkspaceWindowIds(oldWindowId: UUID, newWindowId: UUID)
        case removePanelRecords(workspaceIds: Set<UUID>)
    }

    init(
        capacity: Int? = nil,
        fileURL: URL? = nil,
        loadPersisted: Bool = true,
        loadsPersistedRecordsSynchronously: Bool = false,
        persistsRecordsSynchronously: Bool = false
    ) {
        self.capacity = capacity.map { max(1, $0) }
        self.fileURL = fileURL
        self.persistsRecordsSynchronously = persistsRecordsSynchronously
        self.didFinishPersistedRecordsLoad = !loadPersisted || fileURL == nil
        if loadPersisted, let fileURL {
            if loadsPersistedRecordsSynchronously {
                records = Self.loadRecords(fileURL: fileURL)
                trimToCapacityIfNeeded()
                didFinishPersistedRecordsLoad = true
            } else {
                loadPersistedRecordsAsync(from: fileURL)
            }
        }
    }

    var canReopen: Bool {
        !records.isEmpty
    }

    func push(_ entry: ClosedItemHistoryEntry, operationId: UUID? = nil) {
        push(ClosedItemHistoryRecord(operationId: operationId, entry: entry))
    }

    func push(_ record: ClosedItemHistoryRecord) {
        // Recording a new close branches the timeline, so any pending redo
        // (re-close of the last reopened item / operation) no longer applies.
        if redoTarget != nil {
            redoTarget = nil
        }
        if lastRestoredOperationId != nil {
            lastRestoredOperationId = nil
        }
        removeRestoredRefsMatchingClosedEntry(record.entry)
        records.append(record)
        trimToCapacityIfNeeded()
        revision &+= 1
        persistRecords()
    }

    /// Records that `ref` was just reopened from history, making it the target
    /// for a subsequent redo (re-close).
    func noteReopened(_ ref: ReopenedItemRef) {
        redoTarget = ref
        revision &+= 1
    }

    /// Clears any pending redo target.
    func clearRedoTarget() {
        clearRedoTargetAndRestoredOperation()
    }

    /// Marks the operation most recently restored, so a redo can re-close it.
    func setLastRestoredOperation(_ operationId: UUID?) {
        guard lastRestoredOperationId != operationId else { return }
        lastRestoredOperationId = operationId
        revision &+= 1
    }

    @discardableResult
    func restoreFirstRestorable(using restore: (ClosedItemHistoryEntry) -> Bool) -> Bool {
        restoreFirstRestorable(newerThan: nil, using: restore)
    }

    @discardableResult
    func restoreFirstRestorable(
        newerThan cutoff: Date?,
        excluding excludedRecordIds: Set<UUID> = [],
        onFailure: ((UUID) -> Void)? = nil,
        using restore: (ClosedItemHistoryEntry) -> Bool
    ) -> Bool {
        let candidates = records.enumerated()
            .filter { _, record in
                guard !excludedRecordIds.contains(record.id) else { return false }
                guard !isRecordRestored(record.id) else { return false }
                guard let cutoff else { return true }
                return record.closedAt >= cutoff
            }
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt > rhs.element.closedAt
                }
                return lhs.offset > rhs.offset
            }
            .map { _, record in (id: record.id, entry: record.entry) }
        for candidate in candidates {
            guard restore(candidate.entry) else {
                onFailure?(candidate.id)
                continue
            }
            return true
        }
        return false
    }

    @discardableResult
    func restoreFirstRestorableRef(
        newerThan cutoff: Date? = nil,
        excluding excludedRecordIds: Set<UUID> = [],
        onFailure: ((UUID) -> Void)? = nil,
        using restore: (ClosedItemHistoryRecord) -> ReopenedItemRef?
    ) -> Bool {
        let candidates = records.enumerated()
            .filter { _, record in
                guard !excludedRecordIds.contains(record.id) else { return false }
                guard !isRecordRestored(record.id) else { return false }
                guard let cutoff else { return true }
                return record.closedAt >= cutoff
            }
            .sorted { lhs, rhs in
                if lhs.element.closedAt != rhs.element.closedAt {
                    return lhs.element.closedAt > rhs.element.closedAt
                }
                return lhs.offset > rhs.offset
            }
            .map { _, record in record }
        for candidate in candidates {
            guard let ref = restore(candidate) else {
                onFailure?(candidate.id)
                continue
            }
            markRestored(recordId: candidate.id, ref: ref)
            setLastRestoredOperation(candidate.operationId)
            return true
        }
        return false
    }

    /// Returns the record with the given id without mutating the log. Used for
    /// non-destructive reopen (the History pane and Recently Closed menu): the
    /// closed-item history is an immutable, append-only log, so reopening an
    /// entry leaves it in place and a later close simply appends a new entry.
    func record(id: UUID) -> ClosedItemHistoryRecord? {
        records.first(where: { $0.id == id })
    }

    func removeRecord(id: UUID) -> (record: ClosedItemHistoryRecord, index: Int)? {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let record = records.remove(at: index)
        pruneRestoredStateForRemovedRecord(record)
        revision &+= 1
        persistRecords()
        return (record, index)
    }

    func insert(_ record: ClosedItemHistoryRecord, at index: Int) {
        records.insert(record, at: min(max(0, index), records.count))
        if let capacity, records.count > capacity {
            let protectedRecordId = record.id
            let overflow = records.count - capacity
            for _ in 0..<overflow {
                guard let removalIndex = records.firstIndex(where: { $0.id != protectedRecordId }) else {
                    pruneRestoredStateForRemovedRecord(records.removeFirst())
                    continue
                }
                pruneRestoredStateForRemovedRecord(records.remove(at: removalIndex))
            }
        }
        revision &+= 1
        persistRecords()
    }

    var totalRecordCount: Int {
        records.count
    }

    func menuSnapshot(maxItemCount: Int? = nil) -> ClosedItemHistoryMenuSnapshot {
        let allItems = records.reversed()
            .filter { !isRecordRestored($0.id) }
            .map(Self.menuItem(for:))
        if let maxItemCount, maxItemCount >= 0, allItems.count > maxItemCount {
            return ClosedItemHistoryMenuSnapshot(
                items: Array(allItems.prefix(maxItemCount)),
                totalItemCount: allItems.count,
                isLimited: true
            )
        }

        return ClosedItemHistoryMenuSnapshot(
            items: allItems,
            totalItemCount: allItems.count,
            isLimited: false
        )
    }

    /// Groups records into operations (newest first) for the History pane. Each
    /// item carries its current restored/live state.
    func operationSnapshot() -> [ClosedOperationSnapshot] {
        var order: [UUID] = []
        var byOp: [UUID: [ClosedItemHistoryRecord]] = [:]
        for record in records.reversed() {
            if byOp[record.operationId] == nil { order.append(record.operationId) }
            byOp[record.operationId, default: []].append(record)
        }
        return order.compactMap { opId -> ClosedOperationSnapshot? in
            guard let recs = byOp[opId], !recs.isEmpty else { return nil }
            let orderedRecords = recs.reversed()
            let items = orderedRecords.map { record -> ClosedItemHistoryMenuItem in
                var item = Self.menuItem(for: record)
                item.isRestored = isRecordRestored(record.id)
                return item
            }
            let closedAt = recs.map(\.closedAt).max() ?? recs[0].closedAt
            return ClosedOperationSnapshot(
                id: opId,
                label: Self.operationLabel(for: items),
                closedAt: closedAt,
                items: items
            )
        }
    }

    /// Returns the newest operation with at least one item that is not live,
    /// without evaluating restored state for every record in the full log.
    func firstUndoableOperation(excluding excludedRecordIds: Set<UUID> = []) -> ClosedOperationSnapshot? {
        var order: [UUID] = []
        var byOp: [UUID: [ClosedItemHistoryRecord]] = [:]
        for record in records.reversed() where !excludedRecordIds.contains(record.id) {
            if byOp[record.operationId] == nil { order.append(record.operationId) }
            byOp[record.operationId, default: []].append(record)
        }

        for opId in order {
            guard let recs = byOp[opId], !recs.isEmpty else { continue }
            let orderedRecords = recs.reversed()
            var hasUnrestoredItem = false
            let items = orderedRecords.map { record -> ClosedItemHistoryMenuItem in
                var item = Self.menuItem(for: record)
                item.isRestored = isRecordRestored(record.id)
                if !item.isRestored {
                    hasUnrestoredItem = true
                }
                return item
            }
            guard hasUnrestoredItem else { continue }
            let closedAt = recs.map(\.closedAt).max() ?? recs[0].closedAt
            return ClosedOperationSnapshot(
                id: opId,
                label: Self.operationLabel(for: items),
                closedAt: closedAt,
                items: items
            )
        }
        return nil
    }

    /// Whether the given record's restored target is currently live (the single
    /// source of truth for "already restored").
    func isRecordRestored(_ recordId: UUID) -> Bool {
        guard let ref = restoredRefByRecordId[recordId], let isTargetLive else { return false }
        return isTargetLive(ref)
    }

    /// Records that `recordId` was restored into the live item `ref`.
    func markRestored(recordId: UUID, ref: ReopenedItemRef) {
        restoredRefByRecordId[recordId] = ref
        revision &+= 1
    }

    /// The live ref a record was restored into, if still tracked.
    func restoredRef(for recordId: UUID) -> ReopenedItemRef? {
        restoredRefByRecordId[recordId]
    }

    private func removeRestoredRefsMatchingClosedEntry(_ entry: ClosedItemHistoryEntry) {
        let closedRef: ReopenedItemRef
        switch entry {
        case .panel(let panelEntry):
            closedRef = .panel(workspaceId: panelEntry.workspaceId, panelId: panelEntry.snapshot.id)
        case .workspace(let workspaceEntry):
            closedRef = .workspace(workspaceId: workspaceEntry.workspaceId)
        case .window(let windowEntry):
            guard let windowId = windowEntry.windowId else { return }
            closedRef = .window(windowId: windowId)
        }
        restoredRefByRecordId = restoredRefByRecordId.filter { $0.value != closedRef }
    }

    /// All records belonging to one operation, in close order (oldest first).
    func recordsForOperation(_ operationId: UUID) -> [ClosedItemHistoryRecord] {
        records.filter { $0.operationId == operationId }
    }

    /// The operationId of the most recently closed record, or nil if empty.
    var mostRecentOperationId: UUID? {
        records.last?.operationId
    }

    private static func operationLabel(for items: [ClosedItemHistoryMenuItem]) -> String {
        guard items.count > 1 else { return items.first?.title ?? "" }
        let kinds = Set(items.map(\.kind))
        let format: String
        if kinds == [.workspace] {
            format = String(localized: "historyPane.group.workspaces", defaultValue: "%d workspaces")
        } else if kinds == [.window] {
            format = String(localized: "historyPane.group.windows", defaultValue: "%d windows")
        } else if kinds.allSatisfy({ $0 != .workspace && $0 != .window }) {
            format = String(localized: "historyPane.group.tabs", defaultValue: "%d tabs")
        } else {
            format = String(localized: "historyPane.group.items", defaultValue: "%d items")
        }
        return String.localizedStringWithFormat(format, items.count)
    }

    func remapPanelWorkspaceIds(
        from oldWorkspaceId: UUID,
        to newWorkspaceId: UUID,
        panelIdMap: [UUID: UUID] = [:]
    ) {
        guard oldWorkspaceId != newWorkspaceId else { return }
        queuePersistedRecordMutationIfLoading(.remapPanelWorkspaceIds(
            oldWorkspaceId: oldWorkspaceId,
            newWorkspaceId: newWorkspaceId,
            panelIdMap: panelIdMap
        ))
        let result = Self.recordsByRemappingPanelWorkspaceIds(
            records,
            from: oldWorkspaceId,
            to: newWorkspaceId,
            panelIdMap: panelIdMap
        )
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func remapPanelAnchorIds(from oldPanelId: UUID, to newPanelId: UUID) {
        guard oldPanelId != newPanelId else { return }
        queuePersistedRecordMutationIfLoading(.remapPanelAnchorIds(
            oldPanelId: oldPanelId,
            newPanelId: newPanelId
        ))
        let result = Self.recordsByRemappingPanelAnchorIds(records, from: oldPanelId, to: newPanelId)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func remapWorkspaceWindowIds(from oldWindowId: UUID, to newWindowId: UUID) {
        guard oldWindowId != newWindowId else { return }
        queuePersistedRecordMutationIfLoading(.remapWorkspaceWindowIds(
            oldWindowId: oldWindowId,
            newWindowId: newWindowId
        ))
        let result = Self.recordsByRemappingWorkspaceWindowIds(records, from: oldWindowId, to: newWindowId)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func removePanelRecords(forWorkspaceIds workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        queuePersistedRecordMutationIfLoading(.removePanelRecords(workspaceIds: workspaceIds))
        let result = Self.recordsByRemovingPanelRecords(records, forWorkspaceIds: workspaceIds)
        if result.didUpdate {
            records = result.records
            revision &+= 1
            persistRecords()
        }
    }

    func removeAll() {
        let hadState = !records.isEmpty
            || redoTarget != nil
            || lastRestoredOperationId != nil
            || !restoredRefByRecordId.isEmpty
            || !didFinishPersistedRecordsLoad
        guard hadState else { return }
        if !didFinishPersistedRecordsLoad {
            shouldDiscardPersistedRecordsOnLoad = true
        }
        records.removeAll(keepingCapacity: false)
        clearRedoTargetAndRestoredOperation(incrementRevision: false)
        restoredRefByRecordId.removeAll(keepingCapacity: false)
        revision &+= 1
        persistRecords()
    }

    private func clearRedoTargetAndRestoredOperation(incrementRevision: Bool = true) {
        let hadState = redoTarget != nil || lastRestoredOperationId != nil
        redoTarget = nil
        lastRestoredOperationId = nil
        if hadState, incrementRevision {
            revision &+= 1
        }
    }

    private func trimToCapacityIfNeeded() {
        guard let capacity, records.count > capacity else { return }
        let removed = Array(records.prefix(records.count - capacity))
        records.removeFirst(records.count - capacity)
        for record in removed {
            pruneRestoredStateForRemovedRecord(record)
        }
    }

    private func pruneRestoredStateForRemovedRecord(_ record: ClosedItemHistoryRecord) {
        if let ref = restoredRefByRecordId.removeValue(forKey: record.id),
           redoTarget == ref {
            redoTarget = nil
        }
        if lastRestoredOperationId == record.operationId,
           !records.contains(where: { $0.operationId == record.operationId }) {
            lastRestoredOperationId = nil
        }
    }

    private func persistRecords() {
        guard let fileURL else { return }
        guard didFinishPersistedRecordsLoad else {
            needsPersistenceAfterPersistedRecordsLoad = true
            return
        }
        let recordsSnapshot = records
        let revisionSnapshot = revision
        if persistsRecordsSynchronously {
            Self.saveRecords(recordsSnapshot, fileURL: fileURL)
        } else {
            Task {
                await ClosedItemHistoryPersistenceActor.shared.save(
                    recordsSnapshot,
                    fileURL: fileURL,
                    revision: revisionSnapshot
                )
            }
        }
    }

    func flushPendingSaves() {
        guard let fileURL else { return }
        if !didFinishPersistedRecordsLoad {
            finishPersistedRecordsLoad(Self.loadRecords(fileURL: fileURL))
        }
        needsPersistenceAfterPersistedRecordsLoad = false
        Self.saveRecords(records, fileURL: fileURL)
    }

    private func loadPersistedRecordsAsync(from fileURL: URL) {
        Task { @MainActor [weak self] in
            let loadedRecords = await ClosedItemHistoryPersistenceActor.shared.load(fileURL: fileURL)
            guard let self, !didFinishPersistedRecordsLoad else { return }
            finishPersistedRecordsLoad(loadedRecords)
            if needsPersistenceAfterPersistedRecordsLoad {
                needsPersistenceAfterPersistedRecordsLoad = false
                persistRecords()
            }
        }
    }

    private func finishPersistedRecordsLoad(_ loadedRecords: [ClosedItemHistoryRecord]) {
        guard !didFinishPersistedRecordsLoad else { return }
        if !shouldDiscardPersistedRecordsOnLoad {
            var loadedRecords = loadedRecords
            let didMutateLoadedRecords = applyPendingPersistedRecordMutations(to: &loadedRecords)
            mergeLoadedPersistedRecords(loadedRecords)
            if didMutateLoadedRecords {
                needsPersistenceAfterPersistedRecordsLoad = true
            }
        } else {
            pendingPersistedRecordMutations.removeAll(keepingCapacity: false)
        }
        didFinishPersistedRecordsLoad = true
        shouldDiscardPersistedRecordsOnLoad = false
    }

    private func queuePersistedRecordMutationIfLoading(_ mutation: PendingPersistedRecordMutation) {
        guard !didFinishPersistedRecordsLoad else { return }
        pendingPersistedRecordMutations.append(mutation)
    }

    @discardableResult
    private func applyPendingPersistedRecordMutations(to loadedRecords: inout [ClosedItemHistoryRecord]) -> Bool {
        guard !pendingPersistedRecordMutations.isEmpty else { return false }
        var didUpdate = false
        for mutation in pendingPersistedRecordMutations {
            let result = Self.recordsByApplying(mutation, to: loadedRecords)
            loadedRecords = result.records
            didUpdate = didUpdate || result.didUpdate
        }
        pendingPersistedRecordMutations.removeAll(keepingCapacity: false)
        return didUpdate
    }

    private static func recordsByApplying(
        _ mutation: PendingPersistedRecordMutation,
        to records: [ClosedItemHistoryRecord]
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        switch mutation {
        case .remapPanelWorkspaceIds(let oldWorkspaceId, let newWorkspaceId, let panelIdMap):
            return recordsByRemappingPanelWorkspaceIds(
                records,
                from: oldWorkspaceId,
                to: newWorkspaceId,
                panelIdMap: panelIdMap
            )
        case .remapPanelAnchorIds(let oldPanelId, let newPanelId):
            return recordsByRemappingPanelAnchorIds(records, from: oldPanelId, to: newPanelId)
        case .remapWorkspaceWindowIds(let oldWindowId, let newWindowId):
            return recordsByRemappingWorkspaceWindowIds(records, from: oldWindowId, to: newWindowId)
        case .removePanelRecords(let workspaceIds):
            return recordsByRemovingPanelRecords(records, forWorkspaceIds: workspaceIds)
        }
    }

    private static func recordsByRemappingPanelWorkspaceIds(
        _ records: [ClosedItemHistoryRecord],
        from oldWorkspaceId: UUID,
        to newWorkspaceId: UUID,
        panelIdMap: [UUID: UUID]
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        func remapAnchor(_ panelId: UUID?) -> UUID? {
            guard let panelId else { return nil }
            return panelIdMap[panelId] ?? panelId
        }
        var didUpdate = false
        let remappedRecords = records.map { record in
            guard case .panel(let panelEntry) = record.entry,
                  panelEntry.workspaceId == oldWorkspaceId else {
                return record
            }
            didUpdate = true
            let fallbackSplitPlacement = panelEntry.fallbackSplitPlacement.map {
                ClosedPanelSplitPlacement(
                    orientation: $0.orientation,
                    insertFirst: $0.insertFirst,
                    anchorPanelId: remapAnchor($0.anchorPanelId)
                )
            }
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, operationId: record.operationId, entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: newWorkspaceId,
                paneId: panelEntry.paneId,
                paneAnchorPanelId: remapAnchor(panelEntry.paneAnchorPanelId),
                restoreInOriginalPane: false,
                tabIndex: panelEntry.tabIndex,
                snapshot: panelEntry.snapshot,
                fallbackSplitPlacement: fallbackSplitPlacement
            )))
        }
        return (remappedRecords, didUpdate)
    }

    private static func recordsByRemappingPanelAnchorIds(
        _ records: [ClosedItemHistoryRecord],
        from oldPanelId: UUID,
        to newPanelId: UUID
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        var didUpdate = false
        let remappedRecords = records.map { record in
            guard case .panel(let panelEntry) = record.entry else { return record }
            let paneAnchorPanelId = panelEntry.paneAnchorPanelId == oldPanelId
                ? newPanelId
                : panelEntry.paneAnchorPanelId
            let fallbackSplitPlacement = panelEntry.fallbackSplitPlacement.map { placement in
                let anchorPanelId = placement.anchorPanelId == oldPanelId
                    ? newPanelId
                    : placement.anchorPanelId
                return ClosedPanelSplitPlacement(
                    orientation: placement.orientation,
                    insertFirst: placement.insertFirst,
                    anchorPanelId: anchorPanelId
                )
            }
            if paneAnchorPanelId != panelEntry.paneAnchorPanelId ||
                fallbackSplitPlacement?.anchorPanelId != panelEntry.fallbackSplitPlacement?.anchorPanelId {
                didUpdate = true
            }
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, operationId: record.operationId, entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: panelEntry.workspaceId,
                paneId: panelEntry.paneId,
                paneAnchorPanelId: paneAnchorPanelId,
                restoreInOriginalPane: panelEntry.restoreInOriginalPane,
                tabIndex: panelEntry.tabIndex,
                snapshot: panelEntry.snapshot,
                fallbackSplitPlacement: fallbackSplitPlacement
            )))
        }
        return (remappedRecords, didUpdate)
    }

    private static func recordsByRemappingWorkspaceWindowIds(
        _ records: [ClosedItemHistoryRecord],
        from oldWindowId: UUID,
        to newWindowId: UUID
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        var didUpdate = false
        let remappedRecords = records.map { record in
            guard case .workspace(let workspaceEntry) = record.entry,
                  workspaceEntry.windowId == oldWindowId else {
                return record
            }
            didUpdate = true
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, operationId: record.operationId, entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspaceEntry.workspaceId,
                windowId: newWindowId,
                workspaceIndex: workspaceEntry.workspaceIndex,
                snapshot: workspaceEntry.snapshot
            )))
        }
        return (remappedRecords, didUpdate)
    }

    private static func recordsByRemovingPanelRecords(
        _ records: [ClosedItemHistoryRecord],
        forWorkspaceIds workspaceIds: Set<UUID>
    ) -> (records: [ClosedItemHistoryRecord], didUpdate: Bool) {
        let filteredRecords = records.filter { record in
            guard case .panel(let panelEntry) = record.entry else { return true }
            return !workspaceIds.contains(panelEntry.workspaceId)
        }
        return (filteredRecords, filteredRecords.count != records.count)
    }

    private func mergeLoadedPersistedRecords(_ loadedRecords: [ClosedItemHistoryRecord]) {
        guard !loadedRecords.isEmpty else { return }
        if records.isEmpty {
            records = loadedRecords
        } else {
            var seenRecordIds = Set(records.map(\.id))
            let missingLoadedRecords = loadedRecords.filter { seenRecordIds.insert($0.id).inserted }
            guard !missingLoadedRecords.isEmpty else { return }
            records = missingLoadedRecords + records
        }
        trimToCapacityIfNeeded()
        revision &+= 1
    }

    nonisolated fileprivate static func loadRecords(fileURL: URL) -> [ClosedItemHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(ClosedItemHistoryPersistenceSnapshot.self, from: data),
           snapshot.version == ClosedItemHistoryPersistenceSnapshot.currentVersion {
            return snapshot.records
        }
        return (try? decoder.decode([ClosedItemHistoryRecord].self, from: data)) ?? []
    }

    nonisolated fileprivate static func saveRecords(_ records: [ClosedItemHistoryRecord], fileURL: URL) {
        guard !records.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    closedItemHistoryLogger.debug(
                        "closedItemHistory.remove.failed file=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let snapshot = ClosedItemHistoryPersistenceSnapshot(records: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            closedItemHistoryLogger.debug(
                "closedItemHistory.save.failed file=\(fileURL.path, privacy: .public) records=\(records.count) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
    }

    nonisolated private static func defaultHistoryFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("closed-item-history-\(safeBundleId).json", isDirectory: false)
    }

    private static func menuItem(for record: ClosedItemHistoryRecord) -> ClosedItemHistoryMenuItem {
        switch record.entry {
        case .panel(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                kind: ClosedItemKind.forPanel(entry.snapshot.type),
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab"),
                closedAt: record.closedAt
            )
        case .workspace(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                kind: .workspace,
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.workspace", defaultValue: "Workspace"),
                closedAt: record.closedAt
            )
        case .window(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                kind: .window,
                title: String(localized: "menu.history.recentlyClosed.kind.window", defaultValue: "Window"),
                detail: windowWorkspaceCountLabel(entry.snapshot.tabManager.workspaces.count),
                closedAt: record.closedAt
            )
        }
    }

    private static func title(for snapshot: SessionPanelSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            snapshot.title,
            snapshot.directory.map { URL(fileURLWithPath: $0).lastPathComponent }
        ]
        if let title = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return title
        }

        switch snapshot.type {
        case .terminal:
            return String(localized: "menu.history.recentlyClosed.panel.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "menu.history.recentlyClosed.panel.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "menu.history.recentlyClosed.panel.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "menu.history.recentlyClosed.panel.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            if let mode = snapshot.rightSidebarTool?.mode {
                return mode.label
            }
            return String(localized: "menu.history.recentlyClosed.panel.tool", defaultValue: "Tool")
        case .project:
            return String(localized: "menu.history.recentlyClosed.panel.project", defaultValue: "Project")
        case .history:
            return String(localized: "history.pane.title", defaultValue: "History")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        }
    }

    private static func title(for snapshot: SessionWorkspaceSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            Optional(snapshot.processTitle),
            directoryTitleCandidate(snapshot.currentDirectory)
        ]
        if let title = candidates.compactMap({ normalizedTitleCandidate($0) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
    }

    private static func directoryTitleCandidate(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func normalizedTitleCandidate(_ candidate: String?) -> String? {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        return trimmed
    }

    private static func windowWorkspaceCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "menu.history.recentlyClosed.window.workspaceCount.one", defaultValue: "1 workspace")
        }
        return String.localizedStringWithFormat(
            String(
                localized: "menu.history.recentlyClosed.window.workspaceCount.other",
                defaultValue: "%d workspaces"
            ),
            count
        )
    }
}

private struct ClosedItemHistoryPersistenceSnapshot: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var records: [ClosedItemHistoryRecord]
}

private actor ClosedItemHistoryPersistenceActor {
    static let shared = ClosedItemHistoryPersistenceActor()

    private var latestRevisionByPath: [String: UInt64] = [:]

    func load(fileURL: URL) -> [ClosedItemHistoryRecord] {
        ClosedItemHistoryStore.loadRecords(fileURL: fileURL)
    }

    func save(_ records: [ClosedItemHistoryRecord], fileURL: URL, revision: UInt64) {
        let path = fileURL.standardizedFileURL.path
        if let latestRevision = latestRevisionByPath[path], revision < latestRevision {
            return
        }
        latestRevisionByPath[path] = revision
        ClosedItemHistoryStore.saveRecords(records, fileURL: fileURL)
    }
}
