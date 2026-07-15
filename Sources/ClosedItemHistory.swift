import Foundation
import Combine
import Bonsplit
import OSLog

private let closedItemHistoryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "ClosedItemHistory"
)

struct ClosedPanelSplitPlacement: Codable {
    let orientation: SplitOrientation
    let insertFirst: Bool
    let anchorPanelId: UUID?
}

struct ClosedPanelHistoryEntry: Codable {
    let workspaceId: UUID
    let paneId: UUID
    let paneAnchorPanelId: UUID?
    let restoreInOriginalPane: Bool
    let tabIndex: Int
    let snapshot: SessionPanelSnapshot
    let fallbackSplitPlacement: ClosedPanelSplitPlacement?

    init(
        workspaceId: UUID,
        paneId: UUID,
        paneAnchorPanelId: UUID? = nil,
        restoreInOriginalPane: Bool = true,
        tabIndex: Int,
        snapshot: SessionPanelSnapshot,
        fallbackSplitPlacement: ClosedPanelSplitPlacement? = nil
    ) {
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.paneAnchorPanelId = paneAnchorPanelId
        self.restoreInOriginalPane = restoreInOriginalPane
        self.tabIndex = tabIndex
        self.snapshot = snapshot
        self.fallbackSplitPlacement = fallbackSplitPlacement
    }
}

struct ClosedWorkspaceHistoryEntry: Codable {
    let workspaceId: UUID
    let windowId: UUID?
    let workspaceIndex: Int
    let snapshot: SessionWorkspaceSnapshot
}

struct ClosedWindowHistoryEntry: Codable {
    let windowId: UUID?
    let snapshot: SessionWindowSnapshot

    let workspaceIds: [UUID]

    init(windowId: UUID? = nil, snapshot: SessionWindowSnapshot, workspaceIds: [UUID] = []) {
        self.windowId = windowId
        self.snapshot = snapshot
        self.workspaceIds = workspaceIds
    }
}

enum ClosedItemHistoryEntry: Codable {
    case panel(ClosedPanelHistoryEntry)
    case workspace(ClosedWorkspaceHistoryEntry)
    case window(ClosedWindowHistoryEntry)
}

struct ClosedItemHistoryRecord: Identifiable, Codable {
    let id: UUID
    let closedAt: Date
    var entry: ClosedItemHistoryEntry

    init(id: UUID = UUID(), closedAt: Date = Date(), entry: ClosedItemHistoryEntry) {
        self.id = id
        self.closedAt = closedAt
        self.entry = entry
    }
}

struct ClosedItemHistoryMenuItem: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let closedAt: Date

    var menuSubtitle: String {
        let closed = String(
            format: String(localized: "historyPane.closedAtFormat", defaultValue: "Closed %@"),
            closedAt.formatted(date: .omitted, time: .shortened)
        )
        return String(
            format: String(localized: "menu.history.menuItemSubtitleFormat", defaultValue: "%1$@, %2$@"),
            detail,
            closed
        )
    }

    var menuTitle: String {
        HistoryMenuLineFormatter.titleWithSubtitle(
            title: title,
            subtitle: menuSubtitle
        )
    }
}

struct ClosedItemHistoryMenuSnapshot {
    let items: [ClosedItemHistoryMenuItem]
    let totalItemCount: Int
    let isLimited: Bool
}

enum ClosedWindowRestoreValidation {
    static func hasUsableRestoredContent(
        snapshot: SessionWindowSnapshot,
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        hasLivePanels: Bool
    ) -> Bool {
        guard hasLivePanels else { return false }
        guard snapshot.hasRestorablePanels else { return true }
        return restoredPanelIdsByWorkspaceIndex.contains { !$0.isEmpty }
    }
}

@MainActor
final class ClosedItemHistoryStore: ObservableObject {
    static let shared = ClosedItemHistoryStore(
        capacity: nil,
        fileURL: defaultHistoryFileURL()
    )

    @Published private(set) var revision: UInt64 = 0
    @Published private var records: [ClosedItemHistoryRecord] = []
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

    func push(_ entry: ClosedItemHistoryEntry) {
        push(ClosedItemHistoryRecord(entry: entry))
    }

    func push(_ record: ClosedItemHistoryRecord) {
        records.append(record)
        trimToCapacityIfNeeded()
        revision &+= 1
        persistRecords()
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
            if let index = records.firstIndex(where: { $0.id == candidate.id }) {
                records.remove(at: index)
                revision &+= 1
                persistRecords()
            }
            return true
        }
        return false
    }

    func removeRecord(id: UUID) -> (record: ClosedItemHistoryRecord, index: Int)? {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let record = records.remove(at: index)
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
                    records.removeFirst()
                    continue
                }
                records.remove(at: removalIndex)
            }
        }
        revision &+= 1
        persistRecords()
    }

    func menuSnapshot(maxItemCount: Int? = nil) -> ClosedItemHistoryMenuSnapshot {
        // Build items only for the records the menu will show — this runs in
        // the App commands body on every menu rebuild, and `records` is
        // unbounded persisted history.
        if let maxItemCount, maxItemCount >= 0, records.count > maxItemCount {
            return ClosedItemHistoryMenuSnapshot(
                items: records.suffix(maxItemCount).reversed().map(Self.menuItem(for:)),
                totalItemCount: records.count,
                isLimited: true
            )
        }

        return ClosedItemHistoryMenuSnapshot(
            items: records.reversed().map(Self.menuItem(for:)),
            totalItemCount: records.count,
            isLimited: false
        )
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
        guard !records.isEmpty || !didFinishPersistedRecordsLoad else { return }
        if !didFinishPersistedRecordsLoad {
            shouldDiscardPersistedRecordsOnLoad = true
        }
        records.removeAll(keepingCapacity: false)
        revision &+= 1
        persistRecords()
    }

    private func trimToCapacityIfNeeded() {
        guard let capacity, records.count > capacity else { return }
        records.removeFirst(records.count - capacity)
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
        let recordsSnapshot = records
        let revisionSnapshot = revision
        if persistsRecordsSynchronously {
            Self.saveRecords(recordsSnapshot, fileURL: fileURL)
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await ClosedItemHistoryPersistenceActor.shared.save(
                recordsSnapshot,
                fileURL: fileURL,
                revision: revisionSnapshot
            )
            semaphore.signal()
        }
        semaphore.wait()
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
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, entry: .panel(ClosedPanelHistoryEntry(
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
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, entry: .panel(ClosedPanelHistoryEntry(
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
            return ClosedItemHistoryRecord(id: record.id, closedAt: record.closedAt, entry: .workspace(ClosedWorkspaceHistoryEntry(
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
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab"),
                closedAt: record.closedAt
            )
        case .workspace(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.workspace", defaultValue: "Workspace"),
                closedAt: record.closedAt
            )
        case .window(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
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
            // String-only path math — NOT URL(fileURLWithPath:), which lstat()s
            // the path to infer directory-ness. These snapshots can hold REMOTE
            // working directories (closed remote-tmux tabs); stat'ing one on the
            // main thread blocks on the autofs automounter (e.g. /home/…) for
            // hundreds of ms per record, and this runs inside the App commands
            // body on every menu rebuild.
            snapshot.directory.map { ($0 as NSString).lastPathComponent }
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
        case .customSidebar:
            return String(localized: "menu.history.recentlyClosed.panel.customSidebar", defaultValue: "Custom Sidebar")
        case .agentSession:
            return String(localized: "menu.history.recentlyClosed.panel.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "menu.history.recentlyClosed.panel.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        case .workspaceTodo:
            return String(localized: "workspaceTodoPane.title", defaultValue: "Todos")
        case .cloudVMLoading:
            return String(localized: "menu.history.recentlyClosed.panel.cloudVM", defaultValue: "Cloud VM")
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
        // String-only path math — see title(for:): URL(fileURLWithPath:) would
        // lstat() a possibly-remote path on the main thread.
        return (trimmed as NSString).lastPathComponent
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
