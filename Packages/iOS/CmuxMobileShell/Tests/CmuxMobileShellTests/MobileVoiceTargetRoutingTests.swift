import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileVoiceTargetRoutingTests {
    @Test func sendsExactTranscriptToRequestedForegroundTerminal() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [MobileShellComposite.targetedVoiceInputCapability]
        )

        let response = try await store.sendVoiceInput(
            text: "swift test --filter Voice",
            submit: true,
            workspaceID: store.workspaces[0].id,
            terminalID: .init(rawValue: RoutingHostRouter.terminalB)
        )

        #expect(response.surfaceID == RoutingHostRouter.terminalB)
        #expect(await router.recordedVoiceInputs() == [
            RoutingHostRouter.VoiceInputRecord(
                workspaceID: RoutingHostRouter.workspaceID,
                surfaceID: RoutingHostRouter.terminalB,
                text: "swift test --filter Voice",
                submit: true
            ),
        ])
    }

    @Test func routesVoiceInputThroughOwningSecondaryMac() async throws {
        let foregroundRouter = RoutingHostRouter()
        let secondaryRouter = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: foregroundRouter,
            hostCapabilities: [MobileShellComposite.targetedVoiceInputCapability]
        )
        store.foregroundMacDeviceID = "mac-a"
        store.workspacesByMac = [
            "mac-a".pairingKey: MacWorkspaceState(
                macDeviceID: "mac-a",
                displayName: "Studio A",
                workspaces: [
                    workspace(macDeviceID: "mac-a", name: "Foreground"),
                ],
                status: .connected
            ),
            MacPairingKey(macDeviceID: "mac-b", instanceTag: "vmini"): MacWorkspaceState(
                macDeviceID: "mac-b",
                instanceTag: "vmini",
                displayName: "Studio B",
                workspaces: [
                    workspace(
                        macDeviceID: "mac-b",
                        instanceTag: "vmini",
                        name: "Secondary"
                    ),
                ],
                status: .connected
            ),
        ]
        try installSecondaryClient(
            on: store,
            macDeviceID: "mac-b",
            instanceTag: "vmini",
            router: secondaryRouter,
            supportedHostCapabilities: [
                MobileShellComposite.targetedVoiceInputCapability,
            ]
        )
        let secondaryWorkspace = try #require(
            store.workspaces.first(where: { $0.macDeviceID == "mac-b" })
        )

        _ = try await store.sendVoiceInput(
            text: "pwd",
            submit: false,
            workspaceID: secondaryWorkspace.id,
            terminalID: .init(rawValue: RoutingHostRouter.terminalA)
        )

        #expect(await foregroundRouter.recordedVoiceInputs().isEmpty)
        #expect(await secondaryRouter.recordedVoiceInputs() == [
            RoutingHostRouter.VoiceInputRecord(
                workspaceID: RoutingHostRouter.workspaceID,
                surfaceID: RoutingHostRouter.terminalA,
                text: "pwd",
                submit: false
            ),
        ])
    }

    private func workspace(
        macDeviceID: String,
        instanceTag: String? = nil,
        name: String
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: RoutingHostRouter.workspaceID),
            macDeviceID: macDeviceID,
            name: name,
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: RoutingHostRouter.terminalA),
                    name: "A"
                ),
                MobileTerminalPreview(
                    id: .init(rawValue: RoutingHostRouter.terminalB),
                    name: "B"
                ),
            ]
        )
        workspace.macInstanceTag = instanceTag
        return workspace
    }
}
