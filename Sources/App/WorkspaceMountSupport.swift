import Combine
import Foundation

enum WorkspaceMountPolicy {
    // Keep only the selected workspace mounted to minimize layer-tree traversal.
    static let maxMountedWorkspaces = 1
    // During workspace cycling, keep only a minimal handoff pair (selected + retiring).
    static let maxMountedWorkspacesDuringCycle = 2

    static func nextMountedWorkspaceIds(
        current: [UUID],
        selected: UUID?,
        pinnedIds: Set<UUID>,
        orderedTabIds: [UUID],
        isCycleHot: Bool,
        maxMounted: Int
    ) -> [UUID] {
        let existing = Set(orderedTabIds)
        let clampedMax = max(1, maxMounted)
        var ordered = current.filter { existing.contains($0) }

        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }

        if isCycleHot, let selected {
            let warmIds = cycleWarmIds(selected: selected, orderedTabIds: orderedTabIds)
            for id in warmIds.reversed() {
                ordered.removeAll { $0 == id }
                ordered.insert(id, at: 0)
            }
        }

        if isCycleHot,
           pinnedIds.isEmpty,
           let selected {
            ordered.removeAll { $0 != selected }
        }

        // Ensure pinned ids (retiring handoff workspaces) are always retained at highest priority.
        // This runs after warming to prevent neighbor warming from evicting the retiring workspace.
        let prioritizedPinnedIds = pinnedIds
            .filter { existing.contains($0) && $0 != selected }
            .sorted { lhs, rhs in
                let lhsIndex = orderedTabIds.firstIndex(of: lhs) ?? .max
                let rhsIndex = orderedTabIds.firstIndex(of: rhs) ?? .max
                return lhsIndex < rhsIndex
            }
        if let selected, existing.contains(selected) {
            ordered.removeAll { $0 == selected }
            ordered.insert(selected, at: 0)
        }
        var pinnedInsertionIndex = (selected != nil) ? 1 : 0
        for pinnedId in prioritizedPinnedIds {
            ordered.removeAll { $0 == pinnedId }
            let insertionIndex = min(pinnedInsertionIndex, ordered.count)
            ordered.insert(pinnedId, at: insertionIndex)
            pinnedInsertionIndex += 1
        }

        if ordered.count > clampedMax {
            ordered.removeSubrange(clampedMax...)
        }

        return ordered
    }

    private static func cycleWarmIds(selected: UUID, orderedTabIds: [UUID]) -> [UUID] {
        guard orderedTabIds.contains(selected) else { return [selected] }
        // Keep warming focused to the selected workspace. Retiring/target workspaces are
        // pinned by handoff logic, so warming adjacent neighbors here just adds layout work.
        return [selected]
    }
}

struct MountedWorkspacePresentation: Equatable {
    let isRenderedVisible: Bool
    let isPanelVisible: Bool
    let renderOpacity: Double
}

enum MountedWorkspacePresentationPolicy {
    static func resolve(
        isSelectedWorkspace: Bool,
        isRetiringWorkspace: Bool,
        shouldPrimeInBackground: Bool
    ) -> MountedWorkspacePresentation {
        let isRenderedVisible = isSelectedWorkspace || isRetiringWorkspace
        let renderOpacity: Double = {
            if isRenderedVisible {
                return 1
            }
            if shouldPrimeInBackground {
                // Keep the workspace mounted long enough to warm the terminal surface, but do
                // not mark it panel-visible. Visible portal entries intentionally survive
                // transient anchor loss during bonsplit drag/reparent churn.
                return 0.001
            }
            return 0
        }()

        return MountedWorkspacePresentation(
            isRenderedVisible: isRenderedVisible,
            isPanelVisible: isRenderedVisible,
            renderOpacity: renderOpacity
        )
    }
}

@MainActor
final class SelectedWorkspaceDirectoryObserver: ObservableObject {
    @Published private(set) var directoryChangeGeneration: UInt64 = 0
    private weak var tabManager: TabManager?
    private var cancellable: AnyCancellable?

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancellable == nil else { return }
        self.tabManager = tabManager
        cancellable = tabManager.$selectedTabId
            .map { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .map { workspace -> AnyPublisher<(UUID?, String?), Never> in
                guard let workspace else {
                    return Just<(UUID?, String?)>((nil, nil)).eraseToAnyPublisher()
                }
                return workspace.$currentDirectory
                    .map { (Optional(workspace.id), Optional($0)) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates { previous, next in
                previous.0 == next.0 && previous.1 == next.1
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.directoryChangeGeneration &+= 1
            }
    }
}
