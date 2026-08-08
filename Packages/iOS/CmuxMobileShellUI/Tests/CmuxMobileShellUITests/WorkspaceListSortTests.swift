import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

/// Behavior tests for the All Computers sort: recency flattening/ordering,
/// single-machine scope exemption, sort-menu gating, and the computer-order
/// editor's effective order.
@MainActor
@Suite struct WorkspaceListSortTests {
    @Test func recencySortOrdersFlatRowsAcrossComputersByLastActivity() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "a-old", macDeviceID: "mac-a", activityAt: 100),
                workspace(id: "a-new", macDeviceID: "mac-a", activityAt: 300),
                workspace(id: "b-mid", macDeviceID: "mac-b", activityAt: 200),
            ],
            store: store,
            workspaceSortMode: .recentActivity
        )

        #expect(view.appliesRecencySort)
        #expect(view.filteredWorkspaces.map(\.id.rawValue) == ["a-new", "b-mid", "a-old"])
    }

    @Test func recencySortFlattensGroupedSections() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var grouped = workspace(id: "a-1", macDeviceID: "mac-a", activityAt: 100)
        grouped.groupID = "group-a"
        let groups = [MobileWorkspaceGroupPreview(
            id: "group-a",
            macDeviceID: "mac-a",
            name: "Group A",
            anchorWorkspaceID: grouped.id
        )]

        let automaticView = workspaceListView(
            workspaces: [grouped],
            groups: groups,
            store: store,
            workspaceSortMode: .automatic
        )
        let recencyView = workspaceListView(
            workspaces: [grouped],
            groups: groups,
            store: store,
            workspaceSortMode: .recentActivity
        )

        #expect(automaticView.rendersGroupedSections)
        #expect(!recencyView.rendersGroupedSections)
    }

    @Test func recencySortDoesNotApplyToSingleMachineScope() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "a-old", macDeviceID: "mac-a", activityAt: 100),
                workspace(id: "a-new", macDeviceID: "mac-a", activityAt: 300),
                workspace(id: "b-mid", macDeviceID: "mac-b", activityAt: 200),
            ],
            store: store,
            macSelection: binding(initialValue: .machine("mac-a")),
            workspaceSortMode: .recentActivity
        )

        // A single Mac's own sidebar order stays authoritative.
        #expect(!view.appliesRecencySort)
        #expect(view.filteredWorkspaces.map(\.id.rawValue) == ["a-old", "a-new"])
    }

    @Test func recencySortDisablesRowReorder() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "a-1", macDeviceID: "mac-a", activityAt: 100),
                workspace(id: "b-1", macDeviceID: "mac-b", activityAt: 200),
            ],
            store: store,
            moveWorkspace: { _, _, _, _ in true },
            workspaceSortMode: .recentActivity
        )

        // The recency order is derived from timestamps; a drag has no spatial
        // destination to send, so reorder must be off regardless of other gates.
        #expect(!view.enablesWorkspaceReorder)
    }

    @Test func sortMenuOffersModesOnlyInAllComputersScope() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let workspaces = [
            workspace(id: "a-1", macDeviceID: "mac-a", activityAt: 100),
            workspace(id: "b-1", macDeviceID: "mac-b", activityAt: 200),
        ]

        let allView = workspaceListView(
            workspaces: workspaces,
            store: store,
            workspaceSortMode: .recentActivity
        )
        let machineView = workspaceListView(
            workspaces: workspaces,
            store: store,
            macSelection: binding(initialValue: .machine("mac-a")),
            workspaceSortMode: .recentActivity
        )

        #expect(allView.workspaceSortMenuMode == .recentActivity)
        #expect(machineView.workspaceSortMenuMode == nil)
    }

    @Test func sortMenuShowsWhenSecondComputerIsPairedButOffline() async throws {
        // A wedged or offline secondary Mac contributes no workspace rows, but
        // the user still owns two computers; hiding the sort control would make
        // it undiscoverable exactly when cross-computer order matters.
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [workspace(id: "a-1", macDeviceID: "mac-a", activityAt: 100)],
            store: store,
            workspaceSortMode: .automatic
        )

        #expect(view.workspaceSortMenuMode == .automatic)
        // The order editor lists the offline computer so it keeps its slot.
        #expect(view.computerOrderSheetMachines.map(\.macDeviceID).contains("mac-b"))
    }

    @Test func sortMenuShowsEvenWithOneOrZeroKnownComputers() async throws {
        // The preference is worth setting before a second computer pairs, and
        // a count gate would hide the control behind connection state.
        let oneMacStore = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
        ])
        let oneMacView = workspaceListView(
            workspaces: [workspace(id: "a-1", macDeviceID: "mac-a", activityAt: 100)],
            store: oneMacStore,
            workspaceSortMode: .automatic
        )
        let emptyStore = await shellStore(pairedMacs: [])
        let emptyView = workspaceListView(
            workspaces: [],
            store: emptyStore,
            workspaceSortMode: .automatic
        )

        #expect(oneMacView.workspaceSortMenuMode == .automatic)
        #expect(emptyView.workspaceSortMenuMode == .automatic)
    }

    @Test func computerOrderSheetListsStoredPriorityFirst() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
            pairedMac(id: "mac-c", name: "Mac C", lastSeenAt: 5),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "a-1", macDeviceID: "mac-a", activityAt: 100),
                workspace(id: "b-1", macDeviceID: "mac-b", activityAt: 200),
                workspace(id: "c-1", macDeviceID: "mac-c", activityAt: 300),
            ],
            store: store,
            workspaceSortMode: .computerPriority,
            workspaceComputerPriority: ["mac-c", "mac-a"]
        )

        let deviceIDs = view.computerOrderSheetMachines.map(\.macDeviceID)
        #expect(deviceIDs.first == "mac-c")
        #expect(deviceIDs.count == 3)
        let cIndex = try #require(deviceIDs.firstIndex(of: "mac-c"))
        let aIndex = try #require(deviceIDs.firstIndex(of: "mac-a"))
        let bIndex = try #require(deviceIDs.firstIndex(of: "mac-b"))
        #expect(cIndex < aIndex && aIndex < bIndex)
    }

    private func workspaceListView(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview] = [],
        store: CMUXMobileShellStore,
        macSelection: Binding<WorkspaceMacSelection>? = nil,
        moveWorkspace: ((
            MobileWorkspacePreview.ID,
            MobileWorkspaceGroupPreview.ID?,
            MobileWorkspacePreview.ID?,
            Bool
        ) async -> Bool)? = nil,
        workspaceSortMode: MobileWorkspaceSortMode = .automatic,
        workspaceComputerPriority: [String] = []
    ) -> WorkspaceListView {
        WorkspaceListView(
            workspaces: workspaces,
            groups: groups,
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .unavailable,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: macSelection ?? binding(initialValue: .all),
            store: store,
            moveWorkspace: moveWorkspace,
            workspaceSortMode: workspaceSortMode,
            setWorkspaceSortMode: { _ in },
            workspaceComputerPriority: workspaceComputerPriority,
            setWorkspaceComputerPriority: { _ in },
            filterState: WorkspaceListFilterState(),
            searchText: ""
        )
    }

    private func binding(initialValue: WorkspaceMacSelection) -> Binding<WorkspaceMacSelection> {
        var value = initialValue
        return Binding(
            get: { value },
            set: { value = $0 }
        )
    }

    private func shellStore(pairedMacs: [MobilePairedMac]) async -> CMUXMobileShellStore {
        let suiteName = "WorkspaceListSortTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .disconnected,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore(pairedMacs),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults,
            groupCollapseStore: MobileWorkspaceGroupCollapseStore(defaults: defaults),
            workspaceSortStore: MobileWorkspaceSortStore(defaults: defaults)
        )
        await store.loadPairedMacs()
        return store
    }

    private func workspace(
        id: String,
        macDeviceID: String,
        activityAt: TimeInterval
    ) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            name: id,
            terminals: []
        )
        preview.lastActivityAt = Date(timeIntervalSince1970: activityAt)
        return preview
    }

    private func pairedMac(
        id: String,
        name: String,
        lastSeenAt: TimeInterval
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a"
        )
    }
}
