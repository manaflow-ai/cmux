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
    let snapshot: SessionWindowSnapshot

    let workspaceIds: [UUID]

    init(snapshot: SessionWindowSnapshot, workspaceIds: [UUID] = []) {
        self.snapshot = snapshot
        self.workspaceIds = workspaceIds
    }
}

enum ClosedItemHistoryEntry {
    case panel(ClosedPanelHistoryEntry)
    case workspace(ClosedWorkspaceHistoryEntry)
    case window(ClosedWindowHistoryEntry)
}

@MainActor
final class ClosedItemHistoryStore: ObservableObject {
    static let shared = ClosedItemHistoryStore(capacity: 50)

    @Published private(set) var revision: UInt64 = 0
    private(set) var entries: [ClosedItemHistoryEntry] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var canReopen: Bool {
        !entries.isEmpty
    }

    func push(_ entry: ClosedItemHistoryEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        revision &+= 1
    }

    func pop() -> ClosedItemHistoryEntry? {
        let entry = entries.popLast()
        if entry != nil {
            revision &+= 1
        }
        return entry
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
        entries = entries.map { entry in
            guard case .panel(let panelEntry) = entry,
                  panelEntry.workspaceId == oldWorkspaceId else {
                return entry
            }
            didUpdate = true
            let fallbackSplitPlacement = panelEntry.fallbackSplitPlacement.map {
                ClosedPanelSplitPlacement(
                    orientation: $0.orientation,
                    insertFirst: $0.insertFirst,
                    anchorPanelId: remapAnchor($0.anchorPanelId)
                )
            }
            return .panel(ClosedPanelHistoryEntry(
                workspaceId: newWorkspaceId,
                paneId: panelEntry.paneId,
                paneAnchorPanelId: remapAnchor(panelEntry.paneAnchorPanelId),
                restoreInOriginalPane: false,
                tabIndex: panelEntry.tabIndex,
                snapshot: panelEntry.snapshot,
                fallbackSplitPlacement: fallbackSplitPlacement
            ))
        }
        if didUpdate {
            revision &+= 1
        }
    }

    func remapPanelAnchorIds(from oldPanelId: UUID, to newPanelId: UUID) {
        guard oldPanelId != newPanelId else { return }
        var didUpdate = false
        entries = entries.map { entry in
            guard case .panel(let panelEntry) = entry else { return entry }
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
            return .panel(ClosedPanelHistoryEntry(
                workspaceId: panelEntry.workspaceId,
                paneId: panelEntry.paneId,
                paneAnchorPanelId: paneAnchorPanelId,
                restoreInOriginalPane: panelEntry.restoreInOriginalPane,
                tabIndex: panelEntry.tabIndex,
                snapshot: panelEntry.snapshot,
                fallbackSplitPlacement: fallbackSplitPlacement
            ))
        }
        if didUpdate {
            revision &+= 1
        }
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll(keepingCapacity: false)
        revision &+= 1
    }
}
