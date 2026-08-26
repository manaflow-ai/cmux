import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression coverage for the forget path's account pinning. A paired-Mac
/// row owned by account A can still be on screen right after auth switches to
/// account B (the list has not refreshed yet). Forgetting it must delete the
/// ROW's owning account's (A) rows, not account B's matching device/tag.
@MainActor
@Suite struct MobileShellCompositeForgetRevokeAccountPinningTests {
    @Test func forgetPinsDeletionToRowOwnerNotLiveAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // One pairing owned by account A, team-less.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-a",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )

        // A second pairing on the same device/tag, owned by account B, must
        // survive account A's forget.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-b",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )

        // Signed in as A when the list is read and the row is hidden.
        let identity = StaticIdentityProvider(userID: "user-a")
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: base,
            identityProvider: identity,
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(store.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        // Auth switches to account B before the user taps forget on the stale row.
        identity.currentUserID = "user-b"

        let cleaned = await store.forgetHiddenComputer(hidden)

        // Deletion is pinned to the row's owner (A): A's row is gone while
        // B's same-device row stays.
        #expect(cleaned)
        #expect(try await base.loadAll(stackUserID: "user-a", teamID: nil).isEmpty)
        #expect(try await base.loadAll(stackUserID: "user-b", teamID: nil).count == 1)
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
