import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@Suite @MainActor struct RegistrySessionHandoffTests {
    @Test func resolvesRuntimeWorkspaceForTheAdvertisingMac() throws {
        var matching = MobileWorkspacePreview(
            id: .init(rawValue: "row-mac-a"),
            macDeviceID: "mac-a",
            name: "Handoff",
            terminals: []
        )
        matching.remoteWorkspaceID = .init(rawValue: "runtime-workspace")
        var otherMac = MobileWorkspacePreview(
            id: .init(rawValue: "row-mac-b"),
            macDeviceID: "mac-b",
            name: "Other",
            terminals: []
        )
        otherMac.remoteWorkspaceID = .init(rawValue: "runtime-workspace")

        let resolved = CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "runtime-workspace",
            deviceID: "mac-a",
            workspaces: [otherMac, matching]
        )

        #expect(resolved == matching.id)
    }

    @Test func staleWorkspaceDoesNotResolve() {
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "row"),
            macDeviceID: "mac-a",
            name: "Still live",
            terminals: []
        )

        #expect(CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "gone",
            deviceID: "mac-a",
            workspaces: [workspace]
        ) == nil)
    }
}
