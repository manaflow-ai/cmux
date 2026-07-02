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

    /// #7158's headline UX: the row disappears (and selection moves to the
    /// neighbor) BEFORE the Mac responds — no laggy wait on the close + refresh
    /// round trips. The router parks the terminal.close response so this state
    /// is observed strictly pre-acknowledgement.
    @Test func closeTerminalRemovesRowAndRepairsSelectionBeforeTheMacResponds() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        seedTerminalCloseWorkspace(on: store, supportsTerminalClose: true)
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        let terminalB = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
        store.selectedWorkspaceID = workspaceID
        store.selectedTerminalID = terminalA
        await router.setHoldFirstTerminalClose(true)

        let close = Task { await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA) }
        await router.awaitFirstTerminalCloseReached()

        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalB])
        #expect(store.selectedTerminalID == terminalB)

        await router.releaseFirstTerminalClose()
        await close.value

        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalB])
        #expect(store.selectedTerminalID == terminalB)
    }

    /// A rejected close must not desync the list (#6349 family): the optimistic
    /// removal rolls back to the Mac's authoritative state on refresh.
    @Test func closeTerminalRestoresRowWhenMacRejectsClose() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        seedTerminalCloseWorkspace(on: store, supportsTerminalClose: true)
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        let terminalB = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
        store.selectedWorkspaceID = workspaceID
        store.selectedTerminalID = terminalA
        await router.setRejectTerminalClose(true)

        await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA)

        #expect(await router.recordedTerminalCloses().count == 1)
        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalA, terminalB])
        // The optimistic neighbor selection ran; it stays valid after the
        // rollback because the neighbor still exists.
        #expect(store.selectedTerminalID == terminalB)
    }

    /// Closing a workspace's only terminal is not offered by the sheet and the
    /// Mac rejects it anyway; the store must not even send the mutation (or
    /// optimistically blank the workspace).
    @Test func closeTerminalKeepsLastRemainingTerminal() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        seedTerminalCloseWorkspace(
            on: store,
            supportsTerminalClose: true,
            terminals: [MobileTerminalPreview(id: terminalA, name: "A")]
        )
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)

        await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA)

        #expect(await router.recordedTerminalCloses().isEmpty)
        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalA])
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
        supportsTerminalClose: Bool,
        terminals: [MobileTerminalPreview]? = nil
    ) {
        let terminals = terminals ?? [
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
