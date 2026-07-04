import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct CreatedTerminalSelectionTests {
    @Test func createdTerminalSelectionSurvivesNotReadyWorkspaceRefresh() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)

        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(
                id: "workspace-main",
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(
                        id: "terminal-build",
                        name: "Build",
                        isReady: true,
                        isFocused: true
                    ),
                    MobileTerminalPreview(
                        id: created,
                        name: "Terminal 4",
                        isReady: false,
                        isFocused: false
                    ),
                ]
            ),
        ])
        store.selectedWorkspaceID = "workspace-main"

        #expect(store.selectedTerminalID == created)
    }

    @Test func createdTerminalSelectionSurvivesRefreshBeforeTerminalAppears() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)

        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(
                id: "workspace-main",
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(
                        id: "terminal-build",
                        name: "Build",
                        isReady: true,
                        isFocused: true
                    ),
                ]
            ),
        ])
        store.selectedWorkspaceID = "workspace-main"

        #expect(store.selectedTerminalID == created)
    }

    @Test func remoteCreatedTerminalSelectionSurvivesNotReadyWorkspaceRefresh() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let created = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.createdTerminal)

        store.createTerminal(in: MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID))
        await router.awaitTerminalCreateRequested()
        await waitUntilSelectedTerminal(store, is: created)
        #expect(store.selectedTerminalID == created)

        await store.refreshWorkspaces()

        #expect(store.selectedTerminalID == created)
    }

    @Test func remoteCreatedTerminalDoesNotReplaceSelectionAfterMacRowSwitch() async throws {
        let router = RoutingHostRouter()
        await router.setHoldTerminalCreateResponse(true)
        let store = try await makeRoutingConnectedStore(router: router)
        let aggregation = MobileWorkspaceAggregation()
        let remoteWorkspaceID = MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID)
        let foregroundKey = MobileShellComposite.foregroundAnonymousKey
        let foregroundRowID = aggregation.rowID(macDeviceID: foregroundKey, workspaceID: remoteWorkspaceID)
        let otherMacID = "other-mac"
        let otherRowID = aggregation.rowID(macDeviceID: otherMacID, workspaceID: remoteWorkspaceID)
        let otherTerminalID = MobileTerminalPreview.ID(rawValue: "term-other")

        store.setWorkspaceStatesForTesting([
            foregroundKey: MacWorkspaceState(
                macDeviceID: foregroundKey,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        name: "Foreground",
                        terminals: [
                            MobileTerminalPreview(
                                id: .init(rawValue: RoutingHostRouter.terminalA),
                                name: "A",
                                isReady: true,
                                isFocused: true
                            ),
                        ]
                    ),
                ],
                status: .connected
            ),
            otherMacID: MacWorkspaceState(
                macDeviceID: otherMacID,
                displayName: "Other Mac",
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        macDeviceID: otherMacID,
                        name: "Other",
                        terminals: [
                            MobileTerminalPreview(
                                id: otherTerminalID,
                                name: "Other",
                                isReady: true,
                                isFocused: true
                            ),
                        ]
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)
        store.selectedWorkspaceID = foregroundRowID

        store.createTerminal(in: foregroundRowID)
        await router.awaitTerminalCreateRequested()
        store.selectedWorkspaceID = otherRowID
        #expect(store.selectedTerminalID == otherTerminalID)

        await router.releaseTerminalCreateResponse()
        await waitUntilWorkspaceContainsTerminal(store, RoutingHostRouter.createdTerminal)

        #expect(store.selectedWorkspaceID == otherRowID)
        #expect(store.selectedTerminalID == otherTerminalID)
    }

    private func waitUntilSelectedTerminal(
        _ store: MobileShellComposite,
        is terminalID: MobileTerminalPreview.ID
    ) async {
        for _ in 0..<50 where store.selectedTerminalID != terminalID {
            await Task.yield()
        }
    }

    private func waitUntilWorkspaceContainsTerminal(
        _ store: MobileShellComposite,
        _ terminalID: String
    ) async {
        for _ in 0..<50 where !store.workspaces.contains(where: { workspace in
            workspace.terminals.contains { $0.id.rawValue == terminalID }
        }) {
            await Task.yield()
        }
    }
}
