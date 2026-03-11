import Combine
import Foundation
import Bonsplit

enum WorkspaceEngineKind: String, CaseIterable, Identifiable, Sendable {
    case legacy
    case graphV1 = "graph-v1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .legacy:
            return String(localized: "debug.workspaceEngine.legacy", defaultValue: "Legacy")
        case .graphV1:
            return String(localized: "debug.workspaceEngine.graphV1", defaultValue: "Graph v1")
        }
    }
}

enum WorkspaceEngineSettings {
    static let defaultEngineKindKey = "debug.workspaceEngine.defaultKind"
    static let environmentOverrideKey = "CMUX_WORKSPACE_ENGINE"
    static let fallbackEngineKind: WorkspaceEngineKind = .legacy

    static func resolve(rawValue: String?) -> WorkspaceEngineKind? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case WorkspaceEngineKind.legacy.rawValue:
            return .legacy
        case WorkspaceEngineKind.graphV1.rawValue, "graph", "graph_v1":
            return .graphV1
        default:
            return nil
        }
    }

    static func defaultEngineKind(
        defaults: UserDefaults = .standard,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> WorkspaceEngineKind {
        if let override = resolve(rawValue: env[environmentOverrideKey]) {
            return override
        }
        return resolve(rawValue: defaults.string(forKey: defaultEngineKindKey)) ?? fallbackEngineKind
    }
}

struct WorkspacePaneGraphState: Equatable, Sendable {
    let paneId: UUID
    let panelIds: [UUID]
    let selectedPanelId: UUID?
}

struct WorkspaceGraphSnapshot: Equatable, Sendable {
    let workspaceId: UUID
    let paneTree: ExternalTreeNode
    let layoutSnapshot: LayoutSnapshot
    let panes: [WorkspacePaneGraphState]
    let focusedPaneId: UUID?
    let focusedPanelId: UUID?
    let zoomedPaneId: UUID?

    var isSplit: Bool {
        panes.count > 1
    }

    var splitZoomRenderIdentity: String {
        zoomedPaneId.map { "zoom:\($0.uuidString)" } ?? "unzoomed"
    }

    func paneState(for paneId: UUID) -> WorkspacePaneGraphState? {
        panes.first(where: { $0.paneId == paneId })
    }

    func selectedPanelId(inPane paneId: PaneID) -> UUID? {
        paneState(for: paneId.id)?.selectedPanelId
    }

    func merged(with live: WorkspaceGraphSnapshot) -> WorkspaceGraphSnapshot {
        let previousPaneStatesById = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) })
        let mergedPanes = live.panes.map { pane in
            guard pane.selectedPanelId == nil,
                  let previousPane = previousPaneStatesById[pane.paneId],
                  let previousSelectedPanelId = previousPane.selectedPanelId,
                  pane.panelIds.contains(previousSelectedPanelId) else {
                return pane
            }
            return WorkspacePaneGraphState(
                paneId: pane.paneId,
                panelIds: pane.panelIds,
                selectedPanelId: previousSelectedPanelId
            )
        }
        let mergedPaneStatesById = Dictionary(uniqueKeysWithValues: mergedPanes.map { ($0.paneId, $0) })
        let allPanelIds = Set(mergedPanes.flatMap(\.panelIds))
        let mergedFocusedPaneId = live.focusedPaneId ?? {
            guard let previousFocusedPaneId = focusedPaneId,
                  mergedPaneStatesById[previousFocusedPaneId] != nil else {
                return nil
            }
            return previousFocusedPaneId
        }()
        let mergedFocusedPanelId = live.focusedPanelId ?? {
            if let mergedFocusedPaneId,
               let selectedPanelId = mergedPaneStatesById[mergedFocusedPaneId]?.selectedPanelId {
                return selectedPanelId
            }
            guard let previousFocusedPanelId = focusedPanelId,
                  allPanelIds.contains(previousFocusedPanelId) else {
                return nil
            }
            return previousFocusedPanelId
        }()
        let mergedZoomedPaneId = live.zoomedPaneId ?? {
            guard live.focusedPaneId == nil,
                  live.focusedPanelId == nil,
                  let previousZoomedPaneId = zoomedPaneId,
                  mergedPaneStatesById[previousZoomedPaneId] != nil else {
                return nil
            }
            return previousZoomedPaneId
        }()

        return WorkspaceGraphSnapshot(
            workspaceId: live.workspaceId,
            paneTree: live.paneTree,
            layoutSnapshot: live.layoutSnapshot,
            panes: mergedPanes,
            focusedPaneId: mergedFocusedPaneId,
            focusedPanelId: mergedFocusedPanelId,
            zoomedPaneId: mergedZoomedPaneId
        )
    }
}

struct WorkspaceEngineRenderInputs: Equatable {
    let orderedWorkspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let retainedWorkspaceIds: Set<UUID>
    let isWorkspaceCycleHot: Bool
    let workspaceSnapshotsById: [UUID: WorkspaceGraphSnapshot]

    init(
        orderedWorkspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        retainedWorkspaceIds: Set<UUID>,
        isWorkspaceCycleHot: Bool,
        workspaceSnapshotsById: [UUID: WorkspaceGraphSnapshot]
    ) {
        self.orderedWorkspaceIds = orderedWorkspaceIds
        self.selectedWorkspaceId = selectedWorkspaceId
        self.retainedWorkspaceIds = retainedWorkspaceIds
        self.isWorkspaceCycleHot = isWorkspaceCycleHot
        self.workspaceSnapshotsById = workspaceSnapshotsById
    }

    @MainActor
    init(tabManager: TabManager, selectedWorkspaceId: UUID? = nil) {
        self.init(
            orderedWorkspaceIds: tabManager.tabs.map(\.id),
            selectedWorkspaceId: selectedWorkspaceId ?? tabManager.selectedTabId,
            retainedWorkspaceIds: tabManager.pendingBackgroundWorkspaceLoadIds.union(tabManager.debugPinnedWorkspaceLoadIds),
            isWorkspaceCycleHot: tabManager.isWorkspaceCycleHot,
            workspaceSnapshotsById: Dictionary(
                uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0.graphSnapshot()) }
            )
        )
    }
}

struct WindowWorkspaceEngineSnapshot: Equatable {
    var mountedWorkspaceIds: [UUID] = []
    var retiringWorkspaceId: UUID?
}

enum WorkspaceEngineSelectionTransition {
    case noHandoff
    case handoffStarted
}

@MainActor
protocol WindowWorkspaceEngine: AnyObject {
    var kind: WorkspaceEngineKind { get }
    var snapshot: WindowWorkspaceEngineSnapshot { get }

    func bootstrap(inputs: WorkspaceEngineRenderInputs)
    @discardableResult
    func selectedWorkspaceDidChange(
        to newSelectedWorkspaceId: UUID?,
        inputs: WorkspaceEngineRenderInputs
    ) -> WorkspaceEngineSelectionTransition
    func reconcile(inputs: WorkspaceEngineRenderInputs)
    func completeWorkspaceHandoff(inputs: WorkspaceEngineRenderInputs)
    func workspaceSnapshot(for workspaceId: UUID) -> WorkspaceGraphSnapshot?
}

@MainActor
final class WindowWorkspaceEngineStore: ObservableObject {
    @Published private(set) var snapshot: WindowWorkspaceEngineSnapshot
    @Published private(set) var kind: WorkspaceEngineKind

    private weak var tabManager: TabManager?
    private var engine: any WindowWorkspaceEngine
    private var handoffFallbackTask: Task<Void, Never>?
    private var handoffCompletionHandler: ((UUID?, String) -> Void)?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        self.kind = tabManager.workspaceEngineKind
        let inputs = WorkspaceEngineRenderInputs(tabManager: tabManager)
        let engine = Self.makeEngine(kind: tabManager.workspaceEngineKind)
        engine.bootstrap(inputs: inputs)
        self.engine = engine
        self.snapshot = engine.snapshot
    }

    func setHandoffCompletionHandler(_ handler: @escaping (UUID?, String) -> Void) {
        handoffCompletionHandler = handler
    }

    func workspaceSnapshot(for workspaceId: UUID) -> WorkspaceGraphSnapshot? {
        engine.workspaceSnapshot(for: workspaceId)
    }

    func reconfigureIfNeeded(kind newKind: WorkspaceEngineKind) {
        guard kind != newKind else { return }
        let previousRetiringWorkspaceId = snapshot.retiringWorkspaceId
        handoffFallbackTask?.cancel()
        handoffFallbackTask = nil

        kind = newKind
        let nextEngine = Self.makeEngine(kind: newKind)
        if let inputs = currentInputs() {
            nextEngine.bootstrap(inputs: inputs)
            snapshot = nextEngine.snapshot
        } else {
            snapshot = WindowWorkspaceEngineSnapshot()
        }
        engine = nextEngine
        handoffCompletionHandler?(previousRetiringWorkspaceId, "engine_switch")
    }

    func selectedWorkspaceDidChange(to newSelectedWorkspaceId: UUID?) {
        let previousRetiringWorkspaceId = snapshot.retiringWorkspaceId
        guard let inputs = currentInputs(selectedWorkspaceId: newSelectedWorkspaceId) else { return }
        let transition = engine.selectedWorkspaceDidChange(
            to: newSelectedWorkspaceId,
            inputs: inputs
        )
        publishSnapshotIfNeeded()

        switch transition {
        case .handoffStarted:
            scheduleHandoffFallback()
        case .noHandoff:
            handoffFallbackTask?.cancel()
            handoffFallbackTask = nil
            handoffCompletionHandler?(previousRetiringWorkspaceId, "no_handoff")
        }
    }

    func reconcile(reason: String) {
        let previousRetiringWorkspaceId = snapshot.retiringWorkspaceId
        guard let inputs = currentInputs() else { return }
        engine.reconcile(inputs: inputs)
        publishSnapshotIfNeeded()

        if previousRetiringWorkspaceId != nil && snapshot.retiringWorkspaceId == nil {
            handoffFallbackTask?.cancel()
            handoffFallbackTask = nil
            handoffCompletionHandler?(previousRetiringWorkspaceId, reason)
        }
    }

    func completeWorkspaceHandoffIfNeeded(
        focusedWorkspaceId: UUID,
        selectedWorkspaceId: UUID?,
        reason: String
    ) {
        guard focusedWorkspaceId == selectedWorkspaceId else { return }
        guard snapshot.retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func completeWorkspaceHandoff(reason: String) {
        let retiringWorkspaceId = snapshot.retiringWorkspaceId
        handoffFallbackTask?.cancel()
        handoffFallbackTask = nil
        handoffCompletionHandler?(retiringWorkspaceId, reason)

        guard let inputs = currentInputs() else { return }
        engine.completeWorkspaceHandoff(inputs: inputs)
        publishSnapshotIfNeeded()
    }

    private func scheduleHandoffFallback() {
        handoffFallbackTask?.cancel()
        handoffFallbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                self?.completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    private func currentInputs(selectedWorkspaceId: UUID? = nil) -> WorkspaceEngineRenderInputs? {
        guard let tabManager else { return nil }
        return WorkspaceEngineRenderInputs(
            tabManager: tabManager,
            selectedWorkspaceId: selectedWorkspaceId
        )
    }

    private func publishSnapshotIfNeeded() {
        let nextSnapshot = engine.snapshot
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot
    }

    private static func makeEngine(kind: WorkspaceEngineKind) -> any WindowWorkspaceEngine {
        switch kind {
        case .legacy:
            return LegacyWindowWorkspaceEngine()
        case .graphV1:
            return GraphWindowWorkspaceEngine()
        }
    }
}

private func computeMountedWorkspaceIds(
    current: [UUID],
    retiringWorkspaceId: UUID?,
    inputs: WorkspaceEngineRenderInputs
) -> [UUID] {
    let handoffPinnedIds = retiringWorkspaceId.map { Set([$0]) } ?? []
    let pinnedIds = handoffPinnedIds.union(inputs.retainedWorkspaceIds)
    let shouldKeepHandoffPair = inputs.isWorkspaceCycleHot && !handoffPinnedIds.isEmpty
    let baseMaxMounted = shouldKeepHandoffPair
        ? WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
        : WorkspaceMountPolicy.maxMountedWorkspaces
    let selectedCount = inputs.selectedWorkspaceId == nil ? 0 : 1
    let maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)

    return WorkspaceMountPolicy.nextMountedWorkspaceIds(
        current: current,
        selected: inputs.selectedWorkspaceId,
        pinnedIds: pinnedIds,
        orderedTabIds: inputs.orderedWorkspaceIds,
        isCycleHot: inputs.isWorkspaceCycleHot,
        maxMounted: maxMounted
    )
}

@MainActor
private final class LegacyWindowWorkspaceEngine: WindowWorkspaceEngine {
    let kind: WorkspaceEngineKind = .legacy
    private(set) var snapshot = WindowWorkspaceEngineSnapshot()
    private var previousSelectedWorkspaceId: UUID?

    func bootstrap(inputs: WorkspaceEngineRenderInputs) {
        previousSelectedWorkspaceId = inputs.selectedWorkspaceId
        snapshot.retiringWorkspaceId = nil
        snapshot.mountedWorkspaceIds = computeMountedWorkspaceIds(
            current: snapshot.mountedWorkspaceIds,
            retiringWorkspaceId: snapshot.retiringWorkspaceId,
            inputs: inputs
        )
    }

    @discardableResult
    func selectedWorkspaceDidChange(
        to newSelectedWorkspaceId: UUID?,
        inputs: WorkspaceEngineRenderInputs
    ) -> WorkspaceEngineSelectionTransition {
        let oldSelectedWorkspaceId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedWorkspaceId

        if let oldSelectedWorkspaceId,
           let newSelectedWorkspaceId,
           oldSelectedWorkspaceId != newSelectedWorkspaceId {
            snapshot.retiringWorkspaceId = oldSelectedWorkspaceId
            snapshot.mountedWorkspaceIds = computeMountedWorkspaceIds(
                current: snapshot.mountedWorkspaceIds,
                retiringWorkspaceId: snapshot.retiringWorkspaceId,
                inputs: inputs
            )
            return .handoffStarted
        }

        snapshot.retiringWorkspaceId = nil
        snapshot.mountedWorkspaceIds = computeMountedWorkspaceIds(
            current: snapshot.mountedWorkspaceIds,
            retiringWorkspaceId: snapshot.retiringWorkspaceId,
            inputs: inputs
        )
        return .noHandoff
    }

    func reconcile(inputs: WorkspaceEngineRenderInputs) {
        previousSelectedWorkspaceId = inputs.selectedWorkspaceId
        if let retiringWorkspaceId = snapshot.retiringWorkspaceId,
           !inputs.orderedWorkspaceIds.contains(retiringWorkspaceId) {
            snapshot.retiringWorkspaceId = nil
        }
        snapshot.mountedWorkspaceIds = computeMountedWorkspaceIds(
            current: snapshot.mountedWorkspaceIds,
            retiringWorkspaceId: snapshot.retiringWorkspaceId,
            inputs: inputs
        )
    }

    func completeWorkspaceHandoff(inputs: WorkspaceEngineRenderInputs) {
        snapshot.retiringWorkspaceId = nil
        snapshot.mountedWorkspaceIds = computeMountedWorkspaceIds(
            current: snapshot.mountedWorkspaceIds,
            retiringWorkspaceId: snapshot.retiringWorkspaceId,
            inputs: inputs
        )
    }

    func workspaceSnapshot(for workspaceId: UUID) -> WorkspaceGraphSnapshot? {
        nil
    }
}

struct WindowGraphState: Equatable {
    enum Action {
        case bootstrap(WorkspaceEngineRenderInputs)
        case selectWorkspace(UUID?, WorkspaceEngineRenderInputs)
        case reconcile(WorkspaceEngineRenderInputs)
        case completeWorkspaceHandoff(WorkspaceEngineRenderInputs)
    }

    var selectedWorkspaceId: UUID?
    var retiringWorkspaceId: UUID?
    var mountedWorkspaceIds: [UUID] = []
    var workspaceSnapshotsById: [UUID: WorkspaceGraphSnapshot] = [:]

    @discardableResult
    mutating func apply(_ action: Action) -> WorkspaceEngineSelectionTransition? {
        func reconcileWorkspaceSnapshots(_ liveSnapshotsById: [UUID: WorkspaceGraphSnapshot]) {
            var nextSnapshotsById: [UUID: WorkspaceGraphSnapshot] = [:]
            nextSnapshotsById.reserveCapacity(liveSnapshotsById.count)

            for (workspaceId, liveSnapshot) in liveSnapshotsById {
                if let previousSnapshot = workspaceSnapshotsById[workspaceId] {
                    nextSnapshotsById[workspaceId] = previousSnapshot.merged(with: liveSnapshot)
                } else {
                    nextSnapshotsById[workspaceId] = liveSnapshot
                }
            }

            workspaceSnapshotsById = nextSnapshotsById
        }

        switch action {
        case .bootstrap(let inputs):
            reconcileWorkspaceSnapshots(inputs.workspaceSnapshotsById)
            selectedWorkspaceId = inputs.selectedWorkspaceId
            retiringWorkspaceId = nil
            mountedWorkspaceIds = computeMountedWorkspaceIds(
                current: mountedWorkspaceIds,
                retiringWorkspaceId: retiringWorkspaceId,
                inputs: inputs
            )
            return nil

        case .selectWorkspace(let nextSelectedWorkspaceId, let inputs):
            reconcileWorkspaceSnapshots(inputs.workspaceSnapshotsById)
            let previousSelectedWorkspaceId = selectedWorkspaceId
            selectedWorkspaceId = nextSelectedWorkspaceId

            if let previousSelectedWorkspaceId,
               let nextSelectedWorkspaceId,
               previousSelectedWorkspaceId != nextSelectedWorkspaceId {
                retiringWorkspaceId = previousSelectedWorkspaceId
                mountedWorkspaceIds = computeMountedWorkspaceIds(
                    current: mountedWorkspaceIds,
                    retiringWorkspaceId: retiringWorkspaceId,
                    inputs: inputs
                )
                return .handoffStarted
            }

            retiringWorkspaceId = nil
            mountedWorkspaceIds = computeMountedWorkspaceIds(
                current: mountedWorkspaceIds,
                retiringWorkspaceId: retiringWorkspaceId,
                inputs: inputs
            )
            return .noHandoff

        case .reconcile(let inputs):
            reconcileWorkspaceSnapshots(inputs.workspaceSnapshotsById)
            selectedWorkspaceId = inputs.selectedWorkspaceId
            if let retiringWorkspaceId,
               !inputs.orderedWorkspaceIds.contains(retiringWorkspaceId) {
                self.retiringWorkspaceId = nil
            }
            mountedWorkspaceIds = computeMountedWorkspaceIds(
                current: mountedWorkspaceIds,
                retiringWorkspaceId: retiringWorkspaceId,
                inputs: inputs
            )
            return nil

        case .completeWorkspaceHandoff(let inputs):
            reconcileWorkspaceSnapshots(inputs.workspaceSnapshotsById)
            selectedWorkspaceId = inputs.selectedWorkspaceId
            retiringWorkspaceId = nil
            mountedWorkspaceIds = computeMountedWorkspaceIds(
                current: mountedWorkspaceIds,
                retiringWorkspaceId: retiringWorkspaceId,
                inputs: inputs
            )
            return nil
        }
    }
}

@MainActor
private final class GraphWindowWorkspaceEngine: WindowWorkspaceEngine {
    let kind: WorkspaceEngineKind = .graphV1
    private var graphState = WindowGraphState()

    var snapshot: WindowWorkspaceEngineSnapshot {
        WindowWorkspaceEngineSnapshot(
            mountedWorkspaceIds: graphState.mountedWorkspaceIds,
            retiringWorkspaceId: graphState.retiringWorkspaceId
        )
    }

    func bootstrap(inputs: WorkspaceEngineRenderInputs) {
        _ = graphState.apply(.bootstrap(inputs))
    }

    @discardableResult
    func selectedWorkspaceDidChange(
        to newSelectedWorkspaceId: UUID?,
        inputs: WorkspaceEngineRenderInputs
    ) -> WorkspaceEngineSelectionTransition {
        graphState.apply(.selectWorkspace(newSelectedWorkspaceId, inputs)) ?? .noHandoff
    }

    func reconcile(inputs: WorkspaceEngineRenderInputs) {
        _ = graphState.apply(.reconcile(inputs))
    }

    func completeWorkspaceHandoff(inputs: WorkspaceEngineRenderInputs) {
        _ = graphState.apply(.completeWorkspaceHandoff(inputs))
    }

    func workspaceSnapshot(for workspaceId: UUID) -> WorkspaceGraphSnapshot? {
        graphState.workspaceSnapshotsById[workspaceId]
    }
}
