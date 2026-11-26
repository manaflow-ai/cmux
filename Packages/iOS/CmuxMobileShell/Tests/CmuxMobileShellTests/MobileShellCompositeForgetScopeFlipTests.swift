import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// A thread-safe mutable box for the active team id, so a test can flip the
/// scope the composite observes partway through an async operation.
private final class MutableTeamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    init(_ value: String?) { storedValue = value }
    var value: String? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

/// A forget capability that flips the composite's active team the moment the
/// revoke runs, so ``MobileShellComposite/forgetHiddenComputer`` exercises the
/// "scope changed while the revoke was in flight" branch.
@MainActor
private final class ScopeFlippingForget: MobileIrohMacForgetting {
    private let onForget: () -> Void
    private(set) var forgottenMacDeviceIDs: [String] = []
    private(set) var forgottenExpectedAccountIDs: [String] = []

    init(onForget: @escaping () -> Void) {
        self.onForget = onForget
    }

    func forgetComputer(
        macDeviceID: String,
        instanceTag _: String?,
        expectedAccountID: String
    ) async throws {
        forgottenMacDeviceIDs.append(macDeviceID)
        forgottenExpectedAccountIDs.append(expectedAccountID)
        onForget()
    }
}

/// Regression coverage for the forget path's local-cleanup scoping: a mid-revoke
/// account/team switch must not leave the forgotten computer's durable row
/// behind. `removeStoredPairedMacRow` targets the CAPTURED scope, so cleanup is
/// safe to run unconditionally; skipping it on a scope flip reported success
/// while the row survived, so returning to the old scope showed the "forgotten"
/// computer again.
@MainActor
@Suite struct MobileShellCompositeForgetScopeFlipTests {
    @Test func forgetRemovesCapturedScopeRowEvenWhenScopeFlipsMidRevoke() async throws {
        let team = MutableTeamBox("team-a")
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(id: "mac-a", host: "100.82.214.112"),
                ],
            ],
            blockedTeams: []
        )
        // The revoke succeeds, then flips the observed team so the post-revoke
        // `isScopeCurrent(capturedScope)` check is false.
        let forget = ScopeFlippingForget { team.value = "team-b" }
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: pairedStore,
            personalIrohForget: forget,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(store.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        #expect(forget.forgottenMacDeviceIDs == ["mac-a"])
        // The forget receives the captured account, not whatever is current after
        // the scope flip, so it can pin the revoke to the row's owning session.
        #expect(forget.forgottenExpectedAccountIDs == ["user-1"])
        // The scope flipped to team-b mid-revoke, but cleanup still targets the
        // captured team-a scope, so the durable row is gone from team-a.
        let remaining = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
            .map(\.macDeviceID)
        #expect(!remaining.contains("mac-a"))
    }

    private static func pairedMac(
        id: String,
        host: String,
        port: Int = 50922
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: "Desk Mac",
            routes: [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: nil
        )
    }
}
