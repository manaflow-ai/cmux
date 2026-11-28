import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// A forget capability that records the `expectedAccountID` the composite pins
/// each revoke to, so a test can prove the revoke targets the ROW's owning
/// account rather than whatever account is live when the revoke runs.
@MainActor
private final class RecordingExpectedAccountForget: MobileIrohMacForgetting {
    private(set) var expectedAccountIDs: [String] = []

    func forgetComputer(
        macDeviceID _: String,
        instanceTag _: String?,
        expectedAccountID: String
    ) async throws {
        expectedAccountIDs.append(expectedAccountID)
    }
}

/// Regression coverage for the forget path's revoke-account pinning. A paired-Mac
/// row owned by account A can still be on screen right after auth switches to
/// account B (the list has not refreshed yet). Forgetting it must pin the revoke
/// to the ROW's owning account (A), not the live session (B): the runtime forget
/// checks the pinned account against the live session and fails closed on a
/// mismatch, so passing the live account (B) would let it revoke B's matching
/// device/tag while local cleanup deletes A's row. The row's captured
/// `stackUserID` is the only correct account to revoke against.
@MainActor
@Suite struct MobileShellCompositeForgetRevokeAccountPinningTests {
    @Test func forgetPinsRevokeToRowOwnerNotLiveAccount() async throws {
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

        // Signed in as A when the list is read and the row is hidden.
        let identity = StaticIdentityProvider(userID: "user-a")
        let forget = RecordingExpectedAccountForget()
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: base,
            personalIrohForget: forget,
            identityProvider: identity,
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(store.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        // Auth switches to account B before the user taps forget on the stale row.
        identity.currentUserID = "user-b"

        _ = await store.forgetHiddenComputer(hidden)

        // The revoke must be pinned to the row's owner (A), so the runtime forget
        // fails closed instead of revoking as the live account (B).
        #expect(forget.expectedAccountIDs == ["user-a"])
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}
