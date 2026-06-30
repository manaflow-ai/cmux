import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
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

        #expect(view.macPickerMachines.map(\.id) == ["mac-a", "mac-b"])
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

        #expect(view.macPickerMachines.map(\.name) == ["Desk setup"])
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

    private func workspaceListView(
        workspaces: [MobileWorkspacePreview],
        store: CMUXMobileShellStore
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
            store: store
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
