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
        #expect(store.shouldAutoFocusTerminalSurface(terminalB.rawValue) == false)
        store.consumeTerminalAutoFocusSuppression(for: terminalB.rawValue)
        #expect(store.shouldAutoFocusTerminalSurface(terminalB.rawValue) == true)
    }

    /// A rejected close must not desync the list: the post-mutation refresh keeps
    /// iOS on the Mac's authoritative state.
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
        #expect(store.selectedTerminalID == terminalA)
        #expect(store.shouldAutoFocusTerminalSurface(terminalA.rawValue) == true)
        #expect(store.shouldAutoFocusTerminalSurface(terminalB.rawValue) == true)
    }

    /// iOS does not know the workspace's full panel count, so the host remains
    /// authoritative for the last-surface rule. A one-terminal workspace may
    /// still have another non-terminal surface; when it does not, the Mac
    /// rejects the close and the refresh keeps the terminal.
    @Test func closeTerminalLetsHostRejectLastRemainingSurface() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        seedTerminalCloseWorkspace(
            on: store,
            supportsTerminalClose: true,
            terminals: [MobileTerminalPreview(id: terminalA, name: "A")]
        )
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        await router.setRejectTerminalClose(true)

        await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA)

        let closes = await router.recordedTerminalCloses()
        #expect(closes.map(\.workspaceID) == [RoutingHostRouter.workspaceID])
        #expect(closes.map(\.surfaceID) == [RoutingHostRouter.terminalA])
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
