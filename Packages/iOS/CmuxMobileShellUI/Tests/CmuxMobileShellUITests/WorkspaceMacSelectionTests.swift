import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceMacSelectionTests {
    @Test func pickerIncludesPairedMacWithNoWorkspace() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store
        )

        #expect(view.liveMachineSnapshots.macPickerMachines.map(\.id) == ["mac-a", "mac-b"])
    }

    @Test func titlePickerMachineSelectionSwitchesBeforeApplyingFilter() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                return true
            }
        )

        await view.applyMacTitlePickerSelection(.machine("mac-b"))

        #expect(requestedSwitches == ["mac-b"])
        #expect(selected == .machine("mac-b"))
    }

    @Test func staleTitlePickerMachineSelectionDoesNotSwitch() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                return true
            }
        )

        await view.applyMacTitlePickerSelection(.machine("mac-b"), switchGeneration: 1)

        #expect(requestedSwitches.isEmpty)
        #expect(selected == .all)
    }

    @Test func cancelingPendingTitlePickerSwitchCancelsUnderlyingSwitch() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var selected = WorkspaceMacSelection.all
        var requestedSwitches: [String] = []
        var cancelRestoreRequests: [Bool] = []
        var switchContinuation: CheckedContinuation<Bool, Never>?
        var switchDidStart = false
        var switchStartedContinuation: CheckedContinuation<Void, Never>?
        func markSwitchStarted() {
            guard !switchDidStart else { return }
            switchDidStart = true
            switchStartedContinuation?.resume()
            switchStartedContinuation = nil
        }
        func waitForSwitchStart() async {
            guard !switchDidStart else { return }
            await withCheckedContinuation { continuation in
                if switchDidStart {
                    continuation.resume()
                } else {
                    switchStartedContinuation = continuation
                }
            }
        }
        let view = workspaceListView(
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            store: store,
            macSelection: Binding(
                get: { selected },
                set: { selected = $0 }
            ),
            switchMac: { macDeviceID in
                requestedSwitches.append(macDeviceID)
                markSwitchStarted()
                return await withCheckedContinuation { continuation in
                    switchContinuation = continuation
                }
            },
            cancelMacSwitch: { restorePreviousOnCancel in
                cancelRestoreRequests.append(restorePreviousOnCancel)
            }
        )

        view.handleMacTitlePickerSelection(.machine("mac-b"))
        await waitForSwitchStart()
        let pendingSwitchTask = view.macTitlePickerSwitchTask

        view.handleMacTitlePickerSelection(.all)
        #expect(requestedSwitches == ["mac-b"])
        #expect(cancelRestoreRequests == [true])
        #expect(selected == .all)

        switchContinuation?.resume(returning: true)
        await pendingSwitchTask?.value

        #expect(selected == .all)
    }

    @Test func selectingCoalescedPairedMacMatchesAliasWorkspaceRows() async throws {
        let route = try route(host: "100.82.214.112")
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-old", name: "Desk Mac", route: route, lastSeenAt: 10),
            pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20, isActive: true),
        ])
        #expect(store.displayPairedMacs.map(\.macDeviceID) == ["mac-fresh"])

        let aliasWorkspace = workspace(id: "ws-old", macDeviceID: "mac-old")
        var view = workspaceListView(workspaces: [aliasWorkspace], store: store)
        view.macSelection = .machine("mac-fresh")

        #expect(view.activeFilter.matches(aliasWorkspace))
    }

    @Test func pickerUsesCoalescedCustomNameForRepresentativeMachine() async throws {
        let route = try route(host: "100.82.214.112")
        let store = await shellStore(pairedMacs: [
            pairedMac(
                id: "mac-old",
                name: "Desk Mac",
                route: route,
                lastSeenAt: 10,
                customName: "Desk setup"
            ),
            pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20, isActive: true),
        ])

        let view = workspaceListView(workspaces: [], store: store)

        #expect(view.liveMachineSnapshots.macPickerMachines.map(\.name) == ["Desk setup"])
    }

    @Test func createWorkspaceIsGatedWhenSpecificSelectedMacIsNotForeground() async throws {
        let store = await shellStore(
            pairedMacs: [
                pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20, isActive: true),
                pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
            ],
            connectionState: .connected
        )
        var view = workspaceListView(workspaces: [], store: store)

        view.macSelection = .machine("mac-b")
        #expect(!view.canCreateWorkspaceForMacSelection)

        view.macSelection = .machine("mac-a")
        #expect(view.canCreateWorkspaceForMacSelection)

        view.macSelection = .all
        #expect(view.canCreateWorkspaceForMacSelection)
    }

    @Test func sharedSelectionScopeAllowsCreateWhenConnectedMacIsAlias() {
        let scope = WorkspaceMacSelectionScope(
            selection: .machine("mac-fresh"),
            workspaces: [],
            displayPairedMacs: [
                pairedMac(id: "mac-fresh", name: "Desk Mac", lastSeenAt: 20),
            ],
            foregroundMacDeviceID: "mac-old",
            aliasesFor: { id in
                id == "mac-fresh" ? ["mac-fresh", "mac-old"] : [id]
            }
        )

        #expect(scope.visibleSelection == .machine("mac-fresh"))
        #expect(scope.canCreateWorkspace(base: true))
    }

    @Test func sharedSelectionScopeDisablesCreateWhileMacSwitchPending() {
        let scope = WorkspaceMacSelectionScope(
            selection: .all,
            workspaces: [workspace(id: "ws-a", macDeviceID: "mac-a")],
            displayPairedMacs: [
                pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
                pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
            ],
            foregroundMacDeviceID: "mac-a",
            aliasesFor: { [$0] }
        )

        #expect(!scope.canCreateWorkspace(base: true, switchPending: true))
    }

    @Test func sharedSelectionScopeAllowsCreateWhenManualForegroundMacIsSelected() {
        let manualID = "manual-127.0.0.1:50922"
        let scope = WorkspaceMacSelectionScope(
            selection: .machine(manualID),
            workspaces: [workspace(id: "ws-manual", macDeviceID: manualID)],
            displayPairedMacs: [],
            foregroundMacDeviceID: manualID,
            aliasesFor: { [$0] }
        )

        #expect(scope.visibleSelection == .machine(manualID))
        #expect(scope.canCreateWorkspace(base: true))
    }

    @Test func allMacSelectionPreservesFilterMenuMachineScope() {
        let scope = WorkspaceMacSelectionScope(
            selection: .all,
            workspaces: [
                workspace(id: "ws-a", macDeviceID: "mac-a"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            displayPairedMacs: [],
            foregroundMacDeviceID: nil,
            aliasesFor: { [$0] }
        )
        let active = scope.activeFilter(base: MobileWorkspaceListFilter(machines: ["mac-b"]))

        #expect(active.machines == ["mac-b"])
    }

    @Test func allMacFilterMenuMachineScopeMatchesAliasWorkspaceRows() throws {
        let route = try route(host: "100.82.214.112")
        let aliasWorkspace = workspace(id: "ws-old", macDeviceID: "mac-old")
        let scope = WorkspaceMacSelectionScope(
            selection: .all,
            workspaces: [aliasWorkspace],
            displayPairedMacs: [
                pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20),
            ],
            foregroundMacDeviceID: nil,
            aliasesFor: { id in
                id == "mac-fresh" ? ["mac-fresh", "mac-old"] : [id]
            }
        )

        let active = scope.activeFilter(base: MobileWorkspaceListFilter(machines: ["mac-fresh"]))

        #expect(active.matches(aliasWorkspace))
    }

    @Test func filterMenuMachinesUseRepresentativeIDsForAliasWorkspaces() async throws {
        let route = try route(host: "100.82.214.112")
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-old", name: "Desk Mac", route: route, lastSeenAt: 10),
            pairedMac(id: "mac-fresh", name: "Desk Mac", route: route, lastSeenAt: 20, isActive: true),
            pairedMac(id: "mac-b", name: "Air", lastSeenAt: 15),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "ws-old", macDeviceID: "mac-old"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            store: store
        )

        let machines = view.filterMenuMachines(
            machineSnapshots: view.liveMachineSnapshots,
            visibleSelection: view.visibleMacSelection
        )

        #expect(Set(machines.map(\.id)) == ["mac-b", "mac-fresh"])
        #expect(!machines.map(\.id).contains("mac-old"))
        #expect(view.filterMenuPresentMachineIDs == ["mac-fresh", "mac-b"])
    }

    @Test func filterMenuMachinesHideWhenMacPickerOwnsMachineScope() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        var view = workspaceListView(
            workspaces: [
                workspace(id: "ws-a", macDeviceID: "mac-a"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            store: store
        )
        view.macSelection = .machine("mac-a")

        let machines = view.filterMenuMachines(
            machineSnapshots: view.liveMachineSnapshots,
            visibleSelection: view.visibleMacSelection
        )

        #expect(machines.isEmpty)
    }

    @Test func filterMenuMachinesShowWhenAllMacsCanUseMachineScope() async throws {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-a", name: "Mac A", lastSeenAt: 20),
            pairedMac(id: "mac-b", name: "Mac B", lastSeenAt: 10),
        ])
        let view = workspaceListView(
            workspaces: [
                workspace(id: "ws-a", macDeviceID: "mac-a"),
                workspace(id: "ws-b", macDeviceID: "mac-b"),
            ],
            store: store
        )

        let machines = view.filterMenuMachines(
            machineSnapshots: view.liveMachineSnapshots,
            visibleSelection: view.visibleMacSelection
        )

        #expect(machines.map(\.id) == ["mac-a", "mac-b"])
    }

    @Test func filterMenuPruningClearsMachineSelectionWhenMacPickerOwnsMachineScope() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-b"])
        let changed = filter.pruneMachinesForFilterMenu(visibleMacSelection: .machine("mac-a"))

        #expect(changed)
        #expect(filter.machines.isEmpty)
    }

    @Test func filterMenuPruningKeepsMachineSelectionWhenAllMacsCanUseMachineScope() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-b"])
        let changed = filter.pruneMachinesForFilterMenu(visibleMacSelection: .all)

        #expect(!changed)
        #expect(filter.machines == ["mac-b"])
    }

    @Test func filterMenuPruningClearsSelectionWhenMachineSectionWouldHide() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-a"])
        let changed = filter.pruneMachinesForFilterMenu(presentMachineIDs: ["mac-a"])

        #expect(changed)
        #expect(filter.machines.isEmpty)
    }

    @Test func filterMenuPruningClearsSelectionWhenOnlyDuplicateMachineIDsArePresent() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-a"])
        let changed = filter.pruneMachinesForFilterMenu(presentMachineIDs: ["mac-a", "mac-a"])

        #expect(changed)
        #expect(filter.machines.isEmpty)
    }

    @Test func filterMenuPruningKeepsVisibleMachineSelection() {
        var filter = MobileWorkspaceListFilter(machines: ["mac-a"])
        let changed = filter.pruneMachinesForFilterMenu(presentMachineIDs: ["mac-a", "mac-b"])

        #expect(!changed)
        #expect(filter.machines == ["mac-a"])
    }

    private func workspaceListView(
        workspaces: [MobileWorkspacePreview],
        store: CMUXMobileShellStore,
        macSelection: Binding<WorkspaceMacSelection>? = nil,
        switchMac: (@MainActor (String) async -> Bool)? = nil,
        cancelMacSwitch: (@MainActor (Bool) -> Void)? = nil
    ) -> WorkspaceListView {
        WorkspaceListView(
            workspaces: workspaces,
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .unavailable,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: macSelection ?? binding(initialValue: .all),
            switchMac: switchMac,
            cancelMacSwitch: cancelMacSwitch,
            store: store
        )
    }

    private func binding(initialValue: WorkspaceMacSelection) -> Binding<WorkspaceMacSelection> {
        var value = initialValue
        return Binding(
            get: { value },
            set: { value = $0 }
        )
    }

    private func shellStore(
        pairedMacs: [MobilePairedMac],
        connectionState: MobileConnectionState = .disconnected
    ) async -> CMUXMobileShellStore {
        let suiteName = "WorkspaceMacSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: connectionState,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore(pairedMacs),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        await store.loadPairedMacs()
        return store
    }

    private func workspace(id: String, macDeviceID: String) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: macDeviceID,
            name: "Workspace",
            terminals: []
        )
    }

    private func pairedMac(
        id: String,
        name: String,
        route: CmxAttachRoute? = nil,
        lastSeenAt: TimeInterval,
        isActive: Bool = false,
        customName: String? = nil
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: route.map { [$0] } ?? [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a",
            customName: customName
        )
    }

    private func route(host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "route-\(host)",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: 50922)
        )
    }
}
