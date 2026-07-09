import Foundation
import Testing

@testable import CmuxWorkspaces

@MainActor
@Suite("SessionSnapshotRestoreCoordinator")
struct SessionSnapshotRestoreCoordinatorTests {
    // MARK: - Fakes

    private final class StubTab: WorkspaceTabRepresenting {
        let id: UUID
        var groupId: UUID?
        var isPinned: Bool = false
        var currentDirectory: String = "/tmp"
        var title: String = ""

        init(id: UUID = UUID(), groupId: UUID? = nil) {
            self.id = id
            self.groupId = groupId
        }

        var focusedPanelId: UUID?
        var panelTitles: [UUID: String] = [:]
        func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
        func setCustomColor(_ hex: String?) {}
        func updatePanelTitle(panelId: UUID, title: String) -> Bool { false }
        func applyProcessTitle(_ title: String) {}
        func panelExists(_ panelId: UUID) -> Bool { false }
        func panelId(forSurfaceId surfaceId: UUID) -> UUID? { nil }
    }

    private final class RecordingHost: SessionSnapshotRestoreHosting {
        typealias Tab = StubTab

        var previous: [StubTab] = []
        var build: SessionSnapshotRestoreBuild<StubTab>

        // Recorded sequence of step names, in call order.
        var calls: [String] = []
        // Captured arguments for the steps the coordinator decides.
        var committedTabs: [StubTab] = []
        var committedGroups: [WorkspaceGroup] = []
        var committedKnownGroupIds: Set<UUID> = []
        var committedSelectedTabId: UUID??
        var prunedExistingIds: Set<UUID> = []
        var releasedPrevious: [StubTab] = []
        var scheduledTabs: [StubTab] = []
        var appliedRemaps: [ClosedPanelHistoryRemapOperation] = []
        var postedSelectedTabId: UUID?
        var buildExclusions: Set<UUID>?

        init(build: SessionSnapshotRestoreBuild<StubTab>) {
            self.build = build
        }

        func beginSessionSnapshotRestore() { calls.append("begin") }
        func endSessionSnapshotRestore() { calls.append("end") }
        func currentWorkspaces() -> [StubTab] { calls.append("current"); return previous }
        func resetSubModels(previousTabs: [StubTab]) { calls.append("reset") }
        func buildRestoredWorkspaces(
            excludingStableIdentities: Set<UUID>
        ) -> SessionSnapshotRestoreBuild<StubTab> {
            calls.append("build")
            buildExclusions = excludingStableIdentities
            return build
        }
        func commitRestoredState(
            tabs: [StubTab],
            groups: [WorkspaceGroup],
            knownGroupIds: Set<UUID>,
            selectedTabId: UUID?
        ) {
            calls.append("commit")
            committedTabs = tabs
            committedGroups = groups
            committedKnownGroupIds = knownGroupIds
            committedSelectedTabId = .some(selectedTabId)
        }
        func pruneBackgroundLoadsAndSelection(existingIds: Set<UUID>) {
            calls.append("prune")
            prunedExistingIds = existingIds
        }
        func releaseAwayWorkspaces(_ previousTabs: [StubTab]) {
            calls.append("release")
            releasedPrevious = previousTabs
        }
        func scheduleInitialGitMetadata(for tabs: [StubTab]) {
            calls.append("schedule")
            scheduledTabs = tabs
        }
        func applyClosedPanelHistoryRemaps(_ operations: [ClosedPanelHistoryRemapOperation]) {
            calls.append("remap")
            appliedRemaps = operations
        }
        func postDidFocusTab(selectedTabId: UUID) {
            calls.append("post")
            postedSelectedTabId = selectedTabId
        }
    }

    private func makeCoordinator(
        host: RecordingHost
    ) -> SessionSnapshotRestoreCoordinator<StubTab> {
        let coordinator = SessionSnapshotRestoreCoordinator<StubTab>(
            groupCoordinator: SessionSnapshotGroupCoordinator(),
            remapPlanner: ClosedPanelHistoryRemapPlanner()
        )
        coordinator.attach(host: host)
        return coordinator
    }

    private func build(
        tabs: [StubTab],
        panelMaps: [[UUID: UUID]] = [],
        originalIds: [UUID?] = []
    ) -> SessionSnapshotRestoreBuild<StubTab> {
        SessionSnapshotRestoreBuild(
            tabs: tabs,
            restoredPanelIdsByWorkspaceIndex: panelMaps,
            restoredOriginalWorkspaceIds: originalIds
        )
    }

    // MARK: - Ordering

    @Test("drives the host steps in the legacy restore order")
    func sequenceOrder() {
        let t0 = StubTab()
        let host = RecordingHost(build: build(tabs: [t0]))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: true
        )

        // begin → current → reset → build → commit → prune → release →
        // schedule → remap → post → end (end runs last via defer).
        #expect(host.calls == [
            "begin", "current", "reset", "build", "commit",
            "prune", "release", "schedule", "remap", "post", "end",
        ])
    }

    @Test("no host attached returns empty and drives nothing")
    func noHostNoOp() {
        let coordinator = SessionSnapshotRestoreCoordinator<StubTab>(
            groupCoordinator: SessionSnapshotGroupCoordinator(),
            remapPlanner: ClosedPanelHistoryRemapPlanner()
        )
        let result = coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: true
        )
        #expect(result.isEmpty)
    }

    // MARK: - Selection resolution

    @Test("selects the workspace at the snapshot index when in range")
    func selectsIndexInRange() {
        let t0 = StubTab(); let t1 = StubTab(); let t2 = StubTab()
        let host = RecordingHost(build: build(tabs: [t0, t1, t2]))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: 1,
            remapClosedPanelHistory: false
        )
        #expect(host.committedSelectedTabId == .some(t1.id))
        #expect(host.postedSelectedTabId == t1.id)
    }

    @Test("falls back to the first workspace when the index is out of range")
    func selectsFirstWhenIndexOutOfRange() {
        let t0 = StubTab(); let t1 = StubTab()
        let host = RecordingHost(build: build(tabs: [t0, t1]))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: 9,
            remapClosedPanelHistory: false
        )
        #expect(host.committedSelectedTabId == .some(t0.id))
    }

    @Test("falls back to the first workspace when no index is given")
    func selectsFirstWhenNilIndex() {
        let t0 = StubTab()
        let host = RecordingHost(build: build(tabs: [t0]))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: false
        )
        #expect(host.committedSelectedTabId == .some(t0.id))
    }

    @Test("does not post focus when there are no workspaces to select")
    func noPostWhenNoSelection() {
        let host = RecordingHost(build: build(tabs: []))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: false
        )
        // commit ran with a nil selection (outer .some, inner .none).
        #expect(host.committedSelectedTabId == .some(nil))
        #expect(!host.calls.contains("post"))
    }

    // MARK: - Group rebuild + known-group filter

    @Test("rebuilds groups from members and exposes the known-group filter set")
    func rebuildsGroupsAndKnownIds() {
        let groupId = UUID()
        let anchor = UUID()
        let t0 = StubTab(id: anchor, groupId: groupId)
        let t1 = StubTab(groupId: groupId)
        let host = RecordingHost(build: build(tabs: [t0, t1]))
        let coordinator = makeCoordinator(host: host)

        let snapshot = SessionWorkspaceGroupSnapshot(
            id: groupId,
            name: "G",
            isCollapsed: false,
            anchorWorkspaceId: anchor,
            anchorMemberIndex: 0,
            isPinned: false,
            customColor: nil,
            iconSymbol: nil
        )
        coordinator.restore(
            persistedGroupSnapshots: [snapshot],
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: false
        )
        #expect(host.committedGroups.map(\.id) == [groupId])
        #expect(host.committedKnownGroupIds == [groupId])
    }

    @Test("known-group set is empty when no groups survive")
    func emptyKnownIdsWhenNoGroups() {
        let t0 = StubTab(groupId: UUID())
        let host = RecordingHost(build: build(tabs: [t0]))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: false
        )
        #expect(host.committedGroups.isEmpty)
        #expect(host.committedKnownGroupIds.isEmpty)
    }

    // MARK: - Remap gate

    @Test("skips the closed-panel-history remap when disabled")
    func skipsRemapWhenDisabled() {
        let t0 = StubTab()
        let host = RecordingHost(build: build(tabs: [t0]))
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: false
        )
        #expect(!host.calls.contains("remap"))
    }

    @Test("plans the remap from the build's original ids and returned panel maps")
    func plansRemapFromBuild() {
        let oldId = UUID()
        let newTab = StubTab()
        let panelMap: [UUID: UUID] = [UUID(): UUID()]
        let host = RecordingHost(
            build: build(
                tabs: [newTab],
                panelMaps: [panelMap],
                originalIds: [oldId]
            )
        )
        let coordinator = makeCoordinator(host: host)

        let result = coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: true
        )
        // The planner maps the single old id onto the single restored id with
        // the returned panel map.
        #expect(host.appliedRemaps.count == 1)
        #expect(host.appliedRemaps.first?.fromWorkspaceId == oldId)
        #expect(host.appliedRemaps.first?.toWorkspaceId == newTab.id)
        #expect(host.appliedRemaps.first?.panelIdMap == panelMap)
        // The coordinator returns the build's panel maps verbatim (legacy
        // return value).
        #expect(result == [panelMap])
    }

    // MARK: - Pass-through args

    @Test("prune/release/schedule receive the right id sets and tab lists")
    func passThroughArgs() {
        let prev = StubTab()
        let t0 = StubTab(); let t1 = StubTab()
        let host = RecordingHost(build: build(tabs: [t0, t1]))
        host.previous = [prev]
        let coordinator = makeCoordinator(host: host)

        coordinator.restore(
            persistedGroupSnapshots: nil,
            selectedWorkspaceIndex: nil,
            remapClosedPanelHistory: false
        )
        #expect(host.prunedExistingIds == [t0.id, t1.id])
        #expect(host.releasedPrevious.map(\.id) == [prev.id])
        #expect(host.scheduledTabs.map(\.id) == [t0.id, t1.id])
        #expect(host.committedTabs.map(\.id) == [t0.id, t1.id])
    }
}
