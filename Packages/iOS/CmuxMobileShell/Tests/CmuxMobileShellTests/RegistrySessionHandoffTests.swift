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

    @Test func failedAuthoritativeRefreshDoesNotResolveCachedWorkspace() {
        var cached = MobileWorkspacePreview(
            id: .init(rawValue: "cached-row"),
            macDeviceID: "mac-a",
            name: "Stale cache",
            terminals: []
        )
        cached.remoteWorkspaceID = .init(rawValue: "runtime-workspace")

        #expect(CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "runtime-workspace",
            deviceID: "mac-a",
            workspaces: [cached],
            authoritativeRefreshSucceeded: false
        ) == nil)
    }

    @Test func unknownOwnerDoesNotShadowAdvertisingMac() {
        var unknownOwner = MobileWorkspacePreview(
            id: .init(rawValue: "unknown-owner-row"),
            name: "Unknown owner",
            terminals: []
        )
        unknownOwner.remoteWorkspaceID = .init(rawValue: "runtime-workspace")
        var advertisingMac = MobileWorkspacePreview(
            id: .init(rawValue: "advertising-mac-row"),
            macDeviceID: "mac-a",
            name: "Advertising Mac",
            terminals: []
        )
        advertisingMac.remoteWorkspaceID = .init(rawValue: "runtime-workspace")

        let resolved = CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "runtime-workspace",
            deviceID: "mac-a",
            workspaces: [unknownOwner, advertisingMac]
        )

        #expect(resolved == advertisingMac.id)
    }
}
