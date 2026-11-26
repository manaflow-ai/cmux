import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

/// Behavior tests for the All Computers sort: group-aware recency ordering,
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

    @Test func recencySortKeepsGroupsAtomicAndRanksByNewestMember() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let recencyView = workspaceListView(
            workspaces: [
                workspace(id: "ungrouped", macDeviceID: "mac-b", activityAt: 400),
                workspace(id: "anchor", macDeviceID: "mac-a", activityAt: 100, groupID: "group-a"),
                workspace(id: "member-first", macDeviceID: "mac-a", activityAt: 150, groupID: "group-a"),
                workspace(id: "member-newest", macDeviceID: "mac-a", activityAt: 500, groupID: "group-a"),
            ],
            groups: [group(id: "group-a", anchorID: "anchor", macDeviceID: "mac-a")],
            store: store,
            workspaceSortMode: .recentActivity
        )

        #expect(recencyView.rendersGroupedSections)
        #expect(recencyView.groupedListItems.map(\.id) == [
            "group.group-a",
            "workspace.member-first",
            "workspace.member-newest",
            "groupFooter.group-a",
            "workspace.ungrouped",
        ])
    }

    @Test func recencySortPreservesExpandedCollapsedAndUnreadBehavior() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
        ])
        let workspaces = [
            workspace(id: "anchor", macDeviceID: "mac-a", activityAt: 100, groupID: "group-a"),
            workspace(
                id: "unread-member",
                macDeviceID: "mac-a",
                activityAt: 500,
                groupID: "group-a",
                hasUnread: true
            ),
        ]
        let expandedView = workspaceListView(
            workspaces: workspaces,
            groups: [group(id: "group-a", anchorID: "anchor", macDeviceID: "mac-a")],
            store: store,
            workspaceSortMode: .recentActivity
        )
        let collapsedView = workspaceListView(
            workspaces: workspaces,
            groups: [group(
                id: "group-a",
                anchorID: "anchor",
                macDeviceID: "mac-a",
                isCollapsed: true
            )],
            store: store,
            workspaceSortMode: .recentActivity
        )

        #expect(expandedView.rendersGroupedSections)
        #expect(expandedView.groupedListItems.map(\.id) == [
            "group.group-a",
            "workspace.unread-member",
            "groupFooter.group-a",
        ])
        if case .groupHeader(_, let unread)? = expandedView.groupedListItems.first {
            #expect(!unread.isUnread)
        } else {
            Issue.record("Expanded group did not render a header")
        }
        #expect(collapsedView.rendersGroupedSections)
        #expect(collapsedView.groupedListItems.map(\.id) == ["group.group-a"])
        if case .groupHeader(_, let unread)? = collapsedView.groupedListItems.first {
            #expect(unread.isUnread)
        } else {
            Issue.record("Collapsed group did not render a header")
        }
    }

    @Test func recencySortKeepsMultipleMacGroupsDistinctWithStableMissingAndTiedDates() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let macAGroupID: MobileWorkspaceGroupPreview.ID = "mac-a\u{1F}shared"
        let macBGroupID: MobileWorkspaceGroupPreview.ID = "mac-b\u{1F}shared"
        let view = workspaceListView(
            workspaces: [
                workspace(id: "b-anchor", macDeviceID: "mac-b", activityAt: 300, groupID: macBGroupID),
                workspace(id: "b-member", macDeviceID: "mac-b", activityAt: nil, groupID: macBGroupID),
                workspace(id: "a-anchor", macDeviceID: "mac-a", activityAt: 300, groupID: macAGroupID),
                workspace(id: "a-member", macDeviceID: "mac-a", activityAt: 300, groupID: macAGroupID),
                workspace(id: "tied-root", macDeviceID: "mac-a", activityAt: 300),
                workspace(id: "missing-root", macDeviceID: "mac-b", activityAt: nil),
            ],
            groups: [
                group(id: macBGroupID, anchorID: "b-anchor", macDeviceID: "mac-b", name: "Shared B"),
                group(id: macAGroupID, anchorID: "a-anchor", macDeviceID: "mac-a", name: "Shared A"),
            ],
            store: store,
            workspaceSortMode: .recentActivity
        )

        #expect(view.groupedListItems.map(\.id) == [
            "group.\(macBGroupID.rawValue)",
            "workspace.b-member",
            "groupFooter.\(macBGroupID.rawValue)",
            "group.\(macAGroupID.rawValue)",
            "workspace.a-member",
            "groupFooter.\(macAGroupID.rawValue)",
            "workspace.tied-root",
            "workspace.missing-root",
        ])
    }

    @Test func recencySortRetainsAnchorOnlyGroupAndSafelyIgnoresEmptyMetadata() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "anchor", macDeviceID: "mac-a", activityAt: nil, groupID: "anchor-only"),
                workspace(id: "recent-root", macDeviceID: "mac-a", activityAt: 500),
            ],
            groups: [
                group(id: "anchor-only", anchorID: "anchor", macDeviceID: "mac-a"),
                group(id: "empty", anchorID: "missing-anchor", macDeviceID: "mac-a"),
            ],
            store: store,
            workspaceSortMode: .recentActivity
        )

        #expect(view.groupedListItems.map(\.id) == [
            "workspace.recent-root",
            "group.anchor-only",
        ])
    }

    @Test func groupedProjectionCacheInvalidatesFullInputsSynchronously() throws {
        let cache = WorkspaceListGroupedProjectionCache()
        let groupID: MobileWorkspaceGroupPreview.ID = "group-a"
        var workspaces = [
            workspace(id: "root", macDeviceID: "mac-a", activityAt: 400),
            workspace(
                id: "anchor",
                macDeviceID: "mac-a",
                activityAt: 100,
                groupID: groupID
            ),
            workspace(
                id: "member",
                macDeviceID: "mac-a",
                activityAt: 500,
                groupID: groupID
            ),
        ]
        let expandedGroup = group(
            id: groupID,
            anchorID: "anchor",
            macDeviceID: "mac-a"
        )

        let initial = cache.items(
            workspaces: workspaces,
            groups: [expandedGroup],
            appliesRecencySort: true
        )
        #expect(initial.map(\.id) == [
            "group.group-a",
            "workspace.member",
            "groupFooter.group-a",
            "workspace.root",
        ])
        #expect(cache.items(
            workspaces: workspaces,
            groups: [expandedGroup],
            appliesRecencySort: true
        ) == initial)

        workspaces[2].name = "Renamed member"
        let renamed = cache.items(
            workspaces: workspaces,
            groups: [expandedGroup],
            appliesRecencySort: true
        )
        guard case .workspace(let renamedMember, _)? = renamed.first(where: {
            $0.id == "workspace.member"
        }) else {
            Issue.record("Renamed grouped member was not projected")
            return
        }
        #expect(renamedMember.name == "Renamed member")

        let collapsedGroup = group(
            id: groupID,
            anchorID: "anchor",
            macDeviceID: "mac-a",
            isCollapsed: true
        )
        let collapsed = cache.items(
            workspaces: workspaces,
            groups: [collapsedGroup],
            appliesRecencySort: true
        )
        #expect(collapsed.map(\.id) == ["group.group-a", "workspace.root"])

        let computerOrder = cache.items(
            workspaces: workspaces,
            groups: [expandedGroup],
            appliesRecencySort: false
        )
        #expect(computerOrder.map(\.id) == [
            "workspace.root",
            "group.group-a",
            "workspace.member",
            "groupFooter.group-a",
        ])
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
        #expect(view.computerOrderSheetMachines(
            machineSnapshots: view.liveMachineSnapshots
        ).map(\.macDeviceID).contains("mac-b"))
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

        let deviceIDs = view.computerOrderSheetMachines(
            machineSnapshots: view.liveMachineSnapshots
        ).map(\.macDeviceID)
        #expect(deviceIDs.first == "mac-c")
        #expect(deviceIDs.count == 3)
        let cIndex = try #require(deviceIDs.firstIndex(of: "mac-c"))
        let aIndex = try #require(deviceIDs.firstIndex(of: "mac-a"))
        let bIndex = try #require(deviceIDs.firstIndex(of: "mac-b"))
        #expect(cIndex < aIndex && aIndex < bIndex)
    }

    @Test func computerOrderSheetListsSiblingBuildsAsDistinctComputers() async throws {
        let stableID = MobilePairedMac.pairingID(
            macDeviceID: "mac-a",
            instanceTag: "stable"
        )
        let nightlyID = MobilePairedMac.pairingID(
            macDeviceID: "mac-a",
            instanceTag: "nightly"
        )
        let store = await shellStore(pairedMacs: [
            pairedMac(
                id: "mac-a",
                name: "Mac A",
                lastSeenAt: 20,
                instanceTag: "stable"
            ),
            pairedMac(
                id: "mac-a",
                name: "Mac A",
                lastSeenAt: 10,
                instanceTag: "nightly"
            ),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(
                    id: "stable-1",
                    macDeviceID: "mac-a",
                    activityAt: 100,
                    macInstanceTag: "stable"
                ),
                workspace(
                    id: "nightly-1",
                    macDeviceID: "mac-a",
                    activityAt: 200,
                    macInstanceTag: "nightly"
                ),
            ],
            store: store,
            workspaceSortMode: .computerPriority,
            workspaceComputerPriority: [nightlyID, stableID]
        )

        let machines = view.computerOrderSheetMachines(
            machineSnapshots: view.liveMachineSnapshots
        )
        #expect(machines.map(\.id) == [nightlyID, stableID])
        #expect(machines.map(\.macDeviceID) == ["mac-a", "mac-a"])
        #expect(machines.map(\.instanceTag) == ["nightly", "stable"])
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
        activityAt: TimeInterval?,
        groupID: MobileWorkspaceGroupPreview.ID? = nil,
        hasUnread: Bool = false,
        macInstanceTag: String? = nil
    ) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            name: id,
            groupID: groupID,
            hasUnread: hasUnread,
            terminals: []
        )
        preview.lastActivityAt = activityAt.map(Date.init(timeIntervalSince1970:))
        preview.macInstanceTag = macInstanceTag
        return preview
    }

    private func group(
        id: MobileWorkspaceGroupPreview.ID,
        anchorID: MobileWorkspacePreview.ID,
        macDeviceID: String,
        name: String? = nil,
        isCollapsed: Bool = false
    ) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(
            id: id,
            macDeviceID: macDeviceID,
            name: name ?? id.rawValue,
            isCollapsed: isCollapsed,
            anchorWorkspaceID: anchorID
        )
    }

    private func pairedMac(
        id: String,
        name: String,
        lastSeenAt: TimeInterval,
        instanceTag: String? = nil
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: instanceTag
        )
    }
}
