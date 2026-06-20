import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// End-to-end coverage that a real pairing attempt drives the network /
/// authentication / trust checklist to the right per-gate state (issue #6084):
/// the offline preflight, an on-the-wire auth rejection, an account mismatch, and
/// a clean success each resolve a distinct shape. Reuses the scripted-host
/// harness from `MobileShellRenderGridLivenessTestSupport.swift`.
@Suite @MainActor struct MobileShellCompositeChecklistTests {
    @Test func offlinePreflightFailsOnlyTheNetworkGate() async throws {
        let store = MobileShellComposite(reachability: StubReachability(online: false))
        store.signIn()
        // A non-loopback host triggers the reachability preflight (loopback routes
        // skip it), so the attempt short-circuits before any transport work.
        await store.connectManualHost(name: "Work Mac", host: "100.64.0.1", port: 58_465)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network.isFailed)
        #expect(checklist.authentication == .pending)
        #expect(checklist.trust == .pending)
    }

    @Test func backgroundReconnectDoesNotPublishChecklist() async throws {
        // A non-foreground attempt (background reconnect, host switch, device-tree
        // tap) must not paint the Add Device checklist, so it can never overwrite or
        // render the foreground sheet's state (issue #6084 autoreview follow-up).
        let store = MobileShellComposite(reachability: StubReachability(online: false))
        store.signIn()
        await store.performConnectManualHost(
            name: "Stored Mac",
            host: "100.64.0.1",
            port: 58_465,
            isForegroundPairing: false
        )
        #expect(store.pairingChecklist == nil)
        // The failure is still recorded normally for the (non-checklist) surfaces.
        #expect(store.connectionError != nil)
    }

    @Test func supersedingBackgroundAttemptClearsForegroundChecklist() async throws {
        // A foreground attempt publishes a checklist; a later background attempt
        // (reconnect / host switch) that supersedes it must clear the stale
        // checklist so it can't keep hiding the real error in the Add Device sheet
        // (issue #6084 follow-up).
        let store = MobileShellComposite(reachability: StubReachability(online: false))
        store.signIn()
        await store.connectManualHost(name: "Work Mac", host: "100.64.0.1", port: 58_465)
        #expect(store.pairingChecklist != nil)
        await store.performConnectManualHost(
            name: "Stored Mac",
            host: "100.64.0.2",
            port: 58_465,
            isForegroundPairing: false
        )
        #expect(store.pairingChecklist == nil)
    }

    @Test func backgroundInvalidManualHostClearsForegroundChecklist() async throws {
        let store = MobileShellComposite(reachability: StubReachability(online: false))
        store.signIn()
        await store.connectManualHost(name: "Work Mac", host: "100.64.0.1", port: 58_465)
        #expect(store.pairingChecklist != nil)
        await store.performConnectManualHost(
            name: "Stored Mac",
            host: "bad host",
            port: 58_465,
            isForegroundPairing: false
        )
        #expect(store.pairingChecklist == nil)
        #expect(store.connectionError != nil)
    }

    @Test func backgroundInvalidManualPortClearsForegroundChecklist() async throws {
        let store = MobileShellComposite(reachability: StubReachability(online: false))
        store.signIn()
        await store.connectManualHost(name: "Work Mac", host: "100.64.0.1", port: 58_465)
        #expect(store.pairingChecklist != nil)
        await store.performConnectManualHost(
            name: "Stored Mac",
            host: "100.64.0.2",
            port: 0,
            isForegroundPairing: false
        )
        #expect(store.pairingChecklist == nil)
        #expect(store.connectionError != nil)
    }

    @Test func authRejectionClearsNetworkThenFailsAuthenticationGate() async throws {
        let store = makeStore(errorCode: "unauthorized", message: "invalid token")
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .failed)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication.isFailed)
        #expect(checklist.trust == .pending)
    }

    @Test func accountMismatchClearsNetworkAndAuthThenFailsTrustGate() async throws {
        let store = makeStore(errorCode: "account_mismatch", message: "different account")
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .failed)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication == .succeeded)
        #expect(checklist.trust.isFailed)
    }

    @Test func manualAttachTicketAuthRejectionClearsNetworkAndAuthThenFailsTrust() async throws {
        // The manual flow's pre-connect `mobile.attach_ticket.create` probe reaches
        // the Mac. A host rejection there (account mismatch) must clear the network
        // and authentication gates, not show them untested (issue #6084 follow-up).
        // A loopback host skips the offline preflight and takes the stack-auth
        // attach-ticket path.
        let runtime = LivenessTestRuntime(
            transportFactory: ChecklistErrorTransportFactory(code: "account_mismatch", message: "different account"),
            now: { TestClock().now },
            pairingRequestTimeoutNanoseconds: 5_000_000_000
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        await store.connectManualHost(name: "Work Mac", host: "127.0.0.1", port: 58_465)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication == .succeeded)
        #expect(checklist.trust.isFailed)
    }

    @Test func manualProbeSuccessThenConnectLocalFailureClearsNetworkGate() async throws {
        // The attach-ticket probe succeeds (reaching the Mac), then connect's first
        // request fails locally (Stack token unavailable on the second call). The
        // network gate must stay cleared from the successful probe, not revert to
        // untested (issue #6084 follow-up).
        let provider = FirstCallSucceedsTokenProvider()
        let ticket = try makeTicket(clock: TestClock())
        let runtime = LivenessTestRuntime(
            transportFactory: AttachTicketSuccessTransportFactory(ticket: ticket),
            stackAccessTokenProvider: { try provider.next() },
            stackAccessTokenForceRefresher: { throw TestStackTokenError() },
            now: { TestClock().now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        await store.connectManualHost(name: "Work Mac", host: "127.0.0.1", port: 58_465)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication.isFailed)
    }

    @Test func preSendTokenFailureLeavesNetworkGateUntested() async throws {
        // The Stack token provider fails, so the request never reaches the
        // transport. The auth gate fails, but the network gate must stay untested
        // (not falsely cleared) since no packet left the device (issue #6084).
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
            stackAccessTokenProvider: { throw TestStackTokenError() },
            stackAccessTokenForceRefresher: { throw TestStackTokenError() },
            now: { TestClock().now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .failed)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .pending)
        #expect(checklist.authentication.isFailed)
        #expect(checklist.trust == .pending)
    }

    @Test func unreachableRouteThenPreSendAuthFailureLeavesNetworkUntested() async throws {
        // Multi-route attempt: the first route fails to connect, then a later
        // request fails its Stack-token build before any send. The network gate
        // must stay untested — an unreachable route must not leave a sticky
        // "reached" that greens the network gate (issue #6084 autoreview follow-up).
        let provider = FirstCallSucceedsTokenProvider()
        let runtime = LivenessTestRuntime(
            transportFactory: ConnectFailingTransportFactory(),
            stackAccessTokenProvider: { try provider.next() },
            stackAccessTokenForceRefresher: { throw TestStackTokenError() },
            now: { TestClock().now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTwoRouteTicket()))
        #expect(result == .failed)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .pending)
        #expect(checklist.authentication.isFailed)
        #expect(checklist.trust == .pending)
    }

    @Test func successfulPairingClearsEveryGate() async throws {
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
            now: { TestClock().now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .connected)
        #expect(store.pairingChecklist == .connected)
    }

    // MARK: - Harness

    private func makeStore(errorCode: String?, message: String) -> MobileShellComposite {
        let runtime = LivenessTestRuntime(
            transportFactory: ChecklistErrorTransportFactory(code: errorCode, message: message),
            now: { TestClock().now },
            pairingRequestTimeoutNanoseconds: 5_000_000_000
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        return store
    }

    /// Connect through the QR path, accepting the Mac/iPhone compatibility warning
    /// if prompted (the scripted ticket carries no compatibility version, which the
    /// host treats as a mismatch). Mirrors the user tapping "Continue anyway".
    private func connectAcceptingVersionWarning(
        _ store: MobileShellComposite,
        _ url: String
    ) async -> MobilePairingURLConnectionResult {
        let result = await store.connectPairingURLResult(url)
        guard result == .needsUserApproval else { return result }
        return await store.acceptPairingVersionWarning()
    }

    private func makeTwoRouteTicket() throws -> CmxAttachTicket {
        let routeA = try CmxAttachRoute(
            id: "debug_loopback_a",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 51111)
        )
        let routeB = try CmxAttachRoute(
            id: "debug_loopback_b",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 52222)
        )
        return try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [routeA, routeB],
            expiresAt: TestClock().now.addingTimeInterval(3600)
        )
    }
}
