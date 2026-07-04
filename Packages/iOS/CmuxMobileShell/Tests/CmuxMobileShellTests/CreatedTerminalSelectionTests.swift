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

    @Test func createdTerminalSelectionFallsBackWhenTerminalIsAbsent() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)
        let fallback = MobileTerminalPreview.ID(rawValue: "terminal-build")

        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(
                id: "workspace-main",
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(
                        id: fallback,
                        name: "Build",
                        isReady: true,
                        isFocused: true
                    ),
                ]
            ),
        ])
        store.selectedWorkspaceID = "workspace-main"

        #expect(store.selectedTerminalID == fallback)
        #expect(store.selectedTerminalID != created)
    }

    @Test func createdTerminalPinDoesNotLeakAcrossWorkspaceSwitch() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)
        let otherTerminal = MobileTerminalPreview.ID(rawValue: "workspace-other-terminal-1")

        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(
                id: "workspace-main",
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(id: "terminal-build", name: "Build", isReady: true),
                ]
            ),
            MobileWorkspacePreview(
                id: "workspace-other",
                name: "Other",
                terminals: [
                    MobileTerminalPreview(id: otherTerminal, name: "Other", isReady: true),
                ]
            ),
        ])
        store.selectedWorkspaceID = "workspace-other"

        #expect(store.selectedTerminalID == otherTerminal)
        #expect(store.selectedTerminalID != created)
    }

    @Test func createdTerminalPinSurvivesWorkspaceRowIDRemap() throws {
        let store = MobileShellComposite.preview()
        let aggregation = MobileWorkspaceAggregation()
        let macID = "mac-main"
        let otherMacID = "mac-other"
        let remoteWorkspaceID = MobileWorkspacePreview.ID(rawValue: "shared-workspace")
        let fallback = MobileTerminalPreview.ID(rawValue: "terminal-build")

        store.setWorkspaceStatesForTesting([
            macID: MacWorkspaceState(
                macDeviceID: macID,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        macDeviceID: macID,
                        name: "Main",
                        terminals: [
                            MobileTerminalPreview(id: fallback, name: "Build", isReady: true),
                        ]
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: macID)
        store.selectedWorkspaceID = remoteWorkspaceID

        store.createTerminal(in: remoteWorkspaceID)
        let created = try #require(store.selectedTerminalID)
        let remappedRowID = aggregation.rowID(macDeviceID: macID, workspaceID: remoteWorkspaceID)

        store.setWorkspaceStatesForTesting([
            macID: MacWorkspaceState(
                macDeviceID: macID,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        macDeviceID: macID,
                        name: "Main",
                        terminals: [
                            MobileTerminalPreview(id: fallback, name: "Build", isReady: true),
                            MobileTerminalPreview(id: created, name: "Terminal 2", isReady: false),
                        ]
                    ),
                ],
                status: .connected
            ),
            otherMacID: MacWorkspaceState(
                macDeviceID: otherMacID,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        macDeviceID: otherMacID,
                        name: "Other",
                        terminals: [
                            MobileTerminalPreview(id: "terminal-other", name: "Other", isReady: true),
                        ]
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: macID)

        #expect(store.selectedWorkspaceID == remappedRowID)
        #expect(store.selectedTerminalID == created)
        #expect(store.selectedTerminalID != fallback)
    }

    @Test func createdTerminalPinSurvivesForegroundIdentityAdoption() throws {
        let store = MobileShellComposite.preview()
        let aggregation = MobileWorkspaceAggregation()
        let foregroundKey = MobileShellComposite.foregroundAnonymousKey
        let macID = "mac-main"
        let otherMacID = "mac-other"
        let remoteWorkspaceID = MobileWorkspacePreview.ID(rawValue: "shared-workspace")
        let fallback = MobileTerminalPreview.ID(rawValue: "terminal-build")

        store.setWorkspaceStatesForTesting([
            foregroundKey: MacWorkspaceState(
                macDeviceID: foregroundKey,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        name: "Main",
                        terminals: [
                            MobileTerminalPreview(id: fallback, name: "Build", isReady: true),
                        ]
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: nil)
        store.selectedWorkspaceID = remoteWorkspaceID

        store.createTerminal(in: remoteWorkspaceID)
        let created = try #require(store.selectedTerminalID)
        let remappedRowID = aggregation.rowID(macDeviceID: macID, workspaceID: remoteWorkspaceID)

        store.setWorkspaceStatesForTesting([
            macID: MacWorkspaceState(
                macDeviceID: macID,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        macDeviceID: macID,
                        name: "Main",
                        terminals: [
                            MobileTerminalPreview(id: fallback, name: "Build", isReady: true),
                            MobileTerminalPreview(id: created, name: "Terminal 2", isReady: false),
                        ]
                    ),
                ],
                status: .connected
            ),
            otherMacID: MacWorkspaceState(
                macDeviceID: otherMacID,
                workspaces: [
                    MobileWorkspacePreview(
                        id: remoteWorkspaceID,
                        macDeviceID: otherMacID,
                        name: "Other",
                        terminals: [
                            MobileTerminalPreview(id: "terminal-other", name: "Other", isReady: true),
                        ]
                    ),
                ],
                status: .connected
            ),
        ], foregroundMacDeviceID: macID)

        #expect(store.selectedWorkspaceID == remappedRowID)
        #expect(store.selectedTerminalID == created)
        #expect(store.selectedTerminalID != fallback)
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
