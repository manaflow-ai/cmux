import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Make-before-break admission: a roaming replacement dial may hold a second
/// lease on the exact route its installed predecessor still occupies, and
/// never more than one. Exclusive dials keep today's one-lease rule.
@Suite struct MobileRPCConnectReplacementAdmissionTests {
    private func relayKey() -> MobileRPCConnectAttemptKey {
        let route = try! CmxAttachRoute(
            id: "relay",
            kind: .websocket,
            endpoint: .url("wss://relay.test.cmux.dev/connect"),
            priority: 0
        )
        return MobileRPCConnectAttemptKey(route: route)
    }

    @Test func exclusiveDialStaysGatedBehindInstalledSession() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = relayKey()
        guard case .granted = await registry.beginConnect(key: key) else {
            Issue.record("Expected initial admission")
            return
        }

        #expect(await registry.beginConnect(key: key) == .busy)
    }

    @Test func replacementDialCoexistsWithExactlyOneInstalledSession() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = relayKey()
        guard case let .granted(installed) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected initial admission")
            return
        }

        guard case let .granted(replacement) = await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) else {
            Issue.record("Expected replacement admission beside the installed lease")
            return
        }

        // Never a third same-route session, even for another replacement.
        #expect(await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) == .busy)
        // And an ordinary exclusive dial is refused while two leases live.
        #expect(await registry.beginConnect(key: key) == .busy)

        // Displacing the old session frees its lease; the route returns to a
        // single owner and one more replacement becomes possible.
        await registry.finishConnect(lease: installed)
        guard case let .granted(second) = await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) else {
            Issue.record("Expected replacement admission after the old lease resolved")
            return
        }
        await registry.finishConnect(lease: second)
        await registry.finishConnect(lease: replacement)
    }

    @Test func replacementAdmissionStillHonorsCleanupDebtCap() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = relayKey()
        let firstCleanup = PhysicalCleanupGate()
        let secondCleanup = PhysicalCleanupGate()

        guard case let .granted(first) = await registry.beginConnect(key: key) else {
            Issue.record("Expected first admission")
            return
        }
        await registry.handOffPhysicalCleanup(lease: first) {
            await firstCleanup.wait()
        }
        guard case let .granted(second) = await registry.beginConnect(key: key) else {
            Issue.record("Expected recovery admission with one cleanup debt")
            return
        }
        await registry.handOffPhysicalCleanup(lease: second) {
            await secondCleanup.wait()
        }

        // Two unresolved same-route cleanups block even a replacement dial.
        #expect(await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) == .cleanupBlocked)

        await firstCleanup.release()
        await secondCleanup.release()
    }

    @Test func replacementLeaseTransfersToCleanupIndependently() async {
        let registry = MobileRPCConnectAttemptRegistry()
        let key = relayKey()
        let cleanup = PhysicalCleanupGate()
        guard case let .granted(installed) =
                await registry.beginConnect(key: key) else {
            Issue.record("Expected initial admission")
            return
        }
        guard case let .granted(replacement) = await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) else {
            Issue.record("Expected replacement admission")
            return
        }

        // The displaced session's close becomes tracked cleanup debt and frees
        // its ACTIVE lease: the route is back to one live owner (the
        // replacement), so a further bounded replacement dial is admissible
        // (a second network flap mid-close), while the active-lease cap still
        // refuses a third concurrent session.
        await registry.handOffPhysicalCleanup(lease: installed) {
            await cleanup.wait()
        }
        guard case let .granted(second) = await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) else {
            Issue.record("Expected replacement admission after handoff freed the old active lease")
            return
        }
        #expect(await registry.beginConnect(
            key: key,
            allowsReplacementAlongsideActiveLease: true
        ) == .busy)

        await cleanup.release()
        await registry.finishConnect(lease: second)
        await registry.finishConnect(lease: replacement)
    }
}
