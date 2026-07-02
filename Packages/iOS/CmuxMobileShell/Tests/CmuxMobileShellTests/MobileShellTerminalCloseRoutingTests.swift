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

    /// Overlapping selected-terminal closes must not share one global
    /// suppression bit. If close A completes while close B is still in flight,
    /// A's cleanup must not disarm B's pending selection-repair suppression.
    @Test func overlappingSelectedTerminalClosesKeepRepairSuppressionScoped() async throws {
        let router = RoutingHostRouter()
        await router.setTerminalIDs([
            RoutingHostRouter.terminalA,
            RoutingHostRouter.terminalB,
            RoutingHostRouter.terminalC,
        ])
        await router.holdTerminalCloseRequest(number: 1)
        await router.holdTerminalCloseRequest(number: 2)
        defer {
            Task { await router.releaseAllHeldTerminalCloses() }
        }
        let store = try await makeRoutingConnectedStore(router: router)
        let workspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        let terminalB = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
        let terminalC = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalC)
        seedTerminalCloseWorkspace(
            on: store,
            supportsTerminalClose: true,
            terminals: [
                MobileTerminalPreview(id: terminalA, name: "A"),
                MobileTerminalPreview(id: terminalB, name: "B"),
                MobileTerminalPreview(id: terminalC, name: "C"),
            ]
        )
        store.selectedWorkspaceID = workspaceID
        store.selectedTerminalID = terminalA

        let closeA = Task { await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalA) }
        try #require(await pollUntil { await router.recordedTerminalCloses().count >= 1 })

        store.selectedTerminalID = terminalB
        let closeB = Task { await store.closeTerminal(workspaceID: workspaceID, terminalID: terminalB) }
        try #require(await pollUntil { await router.recordedTerminalCloses().count >= 2 })

        await router.releaseNextHeldTerminalClose()
        await closeA.value
        #expect(store.selectedTerminalID == terminalB)
        #expect(store.shouldAutoFocusTerminalSurface(terminalC.rawValue))

        await router.releaseNextHeldTerminalClose()
        await closeB.value
        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalC])
        #expect(store.selectedTerminalID == terminalC)
        #expect(store.shouldAutoFocusTerminalSurface(terminalC.rawValue) == false)
    }

    /// A selected terminal can belong to a secondary Mac row. The close action
    /// must keep its autofocus suppression armed until the secondary Mac's
    /// authoritative refresh has actually repaired selection.
    @Test func closeTerminalOnSecondaryMacAwaitsRefreshBeforeClearingSuppression() async throws {
        let foregroundRouter = RoutingHostRouter()
        let secondaryRouter = RoutingHostRouter()
        await secondaryRouter.holdTerminalCloseRequest(number: 1)
        defer {
            Task { await secondaryRouter.releaseAllHeldTerminalCloses() }
        }
        let store = try await makeRoutingConnectedStore(router: foregroundRouter)
        try installSecondaryClient(on: store, macDeviceID: "mac-secondary", router: secondaryRouter)
        let terminalA = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalA)
        let terminalB = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.terminalB)
        let secondaryWorkspace = MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID),
            macDeviceID: "mac-secondary",
            name: "Secondary Routing Workspace",
            terminals: [
                MobileTerminalPreview(id: terminalA, name: "A"),
                MobileTerminalPreview(id: terminalB, name: "B"),
            ]
        )
        let foregroundWorkspace = MobileWorkspacePreview(
            id: "foreground-workspace",
            macDeviceID: "test-mac",
            name: "Foreground Workspace",
            terminals: [MobileTerminalPreview(id: "foreground-terminal", name: "Foreground")]
        )
        store.setWorkspaceStatesForTesting([
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                workspaces: [foregroundWorkspace],
                status: .connected
            ),
            "mac-secondary": MacWorkspaceState(
                macDeviceID: "mac-secondary",
                workspaces: [secondaryWorkspace],
                status: .connected,
                actionCapabilities: MobileWorkspaceActionCapabilities(
                    supportsTerminalCloseActions: true
                )
            ),
        ], foregroundMacDeviceID: "test-mac")
        let secondaryRow = try #require(store.workspaces.first {
            $0.macDeviceID == "mac-secondary"
                && $0.rpcWorkspaceID.rawValue == RoutingHostRouter.workspaceID
        })
        store.selectedWorkspaceID = secondaryRow.id
        store.selectedTerminalID = terminalA

        let close = Task { await store.closeTerminal(workspaceID: secondaryRow.id, terminalID: terminalA) }
        try #require(await pollUntil { await secondaryRouter.recordedTerminalCloses().count >= 1 })

        await secondaryRouter.releaseNextHeldTerminalClose()
        await close.value

        #expect(store.selectedWorkspace?.terminals.map(\.id) ?? [] == [terminalB])
        #expect(store.selectedTerminalID == terminalB)
        #expect(store.shouldAutoFocusTerminalSurface(terminalB.rawValue) == false)
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
