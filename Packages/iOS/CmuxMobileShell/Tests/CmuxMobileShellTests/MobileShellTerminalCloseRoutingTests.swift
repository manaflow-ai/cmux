import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

/// Behavior coverage for the terminal picker sheet's swipe-to-delete mutation.
@MainActor
@Suite struct MobileShellTerminalCloseRoutingTests {
    @Test func closeTerminalRoutesOverRPCAndRepairsSelectionFromRefresh() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        seedTerminalCloseWorkspace(on: store, supportsTerminalClose: true)
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        let terminalB = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
        store.selectedWorkspaceID = workspaceID
        store.selectedTerminalID = terminalA

        await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA)

        let closes = await router.recordedTerminalCloses()
        #expect(closes.map(\.workspaceID) == [RoutingHostRouter.workspaceID])
        #expect(closes.map(\.surfaceID) == [RoutingHostRouter.terminalA])
        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalB])
        #expect(store.selectedTerminalID == terminalB)
    }

    @Test func closeTerminalIsHiddenBehindHostCapability() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        seedTerminalCloseWorkspace(on: store, supportsTerminalClose: false)
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)

        await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA)

        #expect(await router.recordedTerminalCloses().isEmpty)
    }

    private func seedTerminalCloseWorkspace(
        on store: MobileShellComposite,
        supportsTerminalClose: Bool
    ) {
        let terminals = [
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
            MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
        ]
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: RoutingHostRouter.workspaceID),
            name: "Routing Workspace",
            terminals: terminals
        )
        store.setWorkspaceStatesForTesting([
            MobileShellComposite.foregroundAnonymousKey: MacWorkspaceState(
                macDeviceID: MobileShellComposite.foregroundAnonymousKey,
                workspaces: [workspace],
                status: .connected,
                actionCapabilities: MobileWorkspaceActionCapabilities(
                    supportsTerminalCloseActions: supportsTerminalClose
                )
            ),
        ], foregroundMacDeviceID: nil)
    }
}
