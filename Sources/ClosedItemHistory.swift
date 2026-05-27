import Foundation
import Combine
import Bonsplit

struct ClosedPanelSplitPlacement {
    let orientation: SplitOrientation
    let insertFirst: Bool
    let anchorPanelId: UUID?
}

struct ClosedPanelHistoryEntry {
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

struct ClosedWorkspaceHistoryEntry {
    let workspaceId: UUID
    let windowId: UUID?
    let workspaceIndex: Int
    let snapshot: SessionWorkspaceSnapshot
}

struct ClosedWindowHistoryEntry {
    let windowId: UUID?
    let snapshot: SessionWindowSnapshot

    let workspaceIds: [UUID]

    init(windowId: UUID? = nil, snapshot: SessionWindowSnapshot, workspaceIds: [UUID] = []) {
        self.windowId = windowId
        self.snapshot = snapshot
        self.workspaceIds = workspaceIds
    }
}

enum ClosedItemHistoryEntry {
    case panel(ClosedPanelHistoryEntry)
    case workspace(ClosedWorkspaceHistoryEntry)
    case window(ClosedWindowHistoryEntry)
}

struct ClosedItemHistoryRecord: Identifiable {
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
    static let shared = ClosedItemHistoryStore(capacity: 50)

    @Published private(set) var revision: UInt64 = 0
    @Published private var records: [ClosedItemHistoryRecord] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var canReopen: Bool {
        !records.isEmpty
    }

    func push(_ entry: ClosedItemHistoryEntry) {
        push(ClosedItemHistoryRecord(entry: entry))
    }

    func push(_ record: ClosedItemHistoryRecord) {
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
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
        return (record, index)
    }

    func insert(_ record: ClosedItemHistoryRecord, at index: Int) {
        records.insert(record, at: min(max(0, index), records.count))
        if records.count > capacity {
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
    }

    func menuSnapshot(maxItemCount: Int? = nil) -> ClosedItemHistoryMenuSnapshot {
        let allItems = records.reversed().map(Self.menuItem(for:))
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

    func remapPanelWorkspaceIds(
        from oldWorkspaceId: UUID,
        to newWorkspaceId: UUID,
        panelIdMap: [UUID: UUID] = [:]
    ) {
        guard oldWorkspaceId != newWorkspaceId else { return }
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
        if didUpdate {
            records = remappedRecords
            revision &+= 1
        }
    }

    func remapPanelAnchorIds(from oldPanelId: UUID, to newPanelId: UUID) {
        guard oldPanelId != newPanelId else { return }
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
        if didUpdate {
            records = remappedRecords
            revision &+= 1
        }
    }

    func remapWorkspaceWindowIds(from oldWindowId: UUID, to newWindowId: UUID) {
        guard oldWindowId != newWindowId else { return }
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
        if didUpdate {
            records = remappedRecords
            revision &+= 1
        }
    }

    func removePanelRecords(forWorkspaceIds workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        let originalCount = records.count
        records.removeAll { record in
            guard case .panel(let panelEntry) = record.entry else { return false }
            return workspaceIds.contains(panelEntry.workspaceId)
        }
        if records.count != originalCount {
            revision &+= 1
        }
    }

    func removeAll() {
        guard !records.isEmpty else { return }
        records.removeAll(keepingCapacity: false)
        revision &+= 1
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
