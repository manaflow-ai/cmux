import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests for the pairing route attempt's pre-dial trust gate: a route the
/// credentialed finalize could never succeed over (outside the Stack-auth
/// trust set) is rejected before the probe ever dials it, preserving the old
/// sequential loop's "never even contact a route we cannot pair over"
/// property under the concurrent probe race.
@Suite struct MobilePairingRouteAttemptTests {
    /// Records `makeTransport` calls so tests can assert a route was never dialed.
    private final class DialRecordingFactory: CmxByteTransportFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var requestedRouteIDsStorage: [String] = []

        var requestedRouteIDs: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requestedRouteIDsStorage
        }

        func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
            lock.lock()
            requestedRouteIDsStorage.append(route.id)
            lock.unlock()
            return NeverConnectTransport()
        }
    }

    private struct NeverConnectTransportError: Error {}

    /// Fails every connect, so a probe that reaches the dial errors fast.
    private struct NeverConnectTransport: CmxByteTransport {
        func connect() async throws { throw NeverConnectTransportError() }
        func receive() async throws -> Data? { nil }
        func send(_ data: Data) async throws { throw NeverConnectTransportError() }
        func close() async {}
    }

    private struct TestShellRuntime: MobileSyncRuntime {
        var transportFactory: any CmxByteTransportFactory
        var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
        var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
        var rpcRequestTimeoutNanoseconds: UInt64 = 1_000_000_000
        var now: @Sendable () -> Date = Date.init
        var supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback]
        var pairingRequestTimeoutNanoseconds: UInt64 = 1_000_000_000
        var supportsServerPushEvents: Bool = true
    }

    private func attempt(
        factory: DialRecordingFactory,
        route: CmxAttachRoute,
        allowsStackAuthFallback: Bool
    ) throws -> MobilePairingRouteAttempt {
        let ticket = try CmxAttachTicket(
            workspaceID: UUID().uuidString,
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        return MobilePairingRouteAttempt(
            runtime: TestShellRuntime(transportFactory: factory),
            ticket: ticket,
            requests: try MobilePairingWorkspaceListRequest.initialRequests(for: ticket),
            allowsStackAuthFallback: allowsStackAuthFallback
        )
    }

    /// A route outside the Stack-auth trust set (an arbitrary public host on a
    /// tailscale-kind route) is rejected before any transport is created: the
    /// finalize could never carry the credential over it, so probing it would
    /// only reveal the device to an attacker-chosen endpoint.
    @Test func probeRefusesUntrustedRouteBeforeDialing() async throws {
        let factory = DialRecordingFactory()
        let route = try CmxAttachRoute(
            id: "untrusted",
            kind: .tailscale,
            endpoint: .hostPort(host: "attacker.example", port: 17_345)
        )
        let attempt = try attempt(factory: factory, route: route, allowsStackAuthFallback: true)

        do {
            _ = try await attempt.probe(route: route)
            Issue.record("probe should refuse an untrusted route")
        } catch let error as MobileShellConnectionError {
            guard case .insecureManualRoute = error else {
                Issue.record("expected insecureManualRoute, got \(error)")
                return
            }
        }
        #expect(factory.requestedRouteIDs.isEmpty)
    }

    /// With Stack-auth fallback disabled for the attempt, even a trusted route
    /// can never finalize, so the probe refuses it pre-dial as well.
    @Test func probeRefusesEveryRouteWhenStackAuthFallbackDisabled() async throws {
        let factory = DialRecordingFactory()
        let route = try CmxAttachRoute(
            id: "loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 17_345)
        )
        let attempt = try attempt(factory: factory, route: route, allowsStackAuthFallback: false)

        do {
            _ = try await attempt.probe(route: route)
            Issue.record("probe should refuse when Stack auth fallback is disabled")
        } catch let error as MobileShellConnectionError {
            guard case .insecureManualRoute = error else {
                Issue.record("expected insecureManualRoute, got \(error)")
                return
            }
        }
        #expect(factory.requestedRouteIDs.isEmpty)
    }

    /// A trusted route passes the gate and reaches the dial: the transport
    /// factory is consulted and its connect failure (not the trust rejection)
    /// is what propagates.
    @Test func probeDialsTrustedRouteAndPropagatesTransportFailure() async throws {
        let factory = DialRecordingFactory()
        let route = try CmxAttachRoute(
            id: "loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 17_345)
        )
        let attempt = try attempt(factory: factory, route: route, allowsStackAuthFallback: true)

        do {
            _ = try await attempt.probe(route: route)
            Issue.record("probe should fail when the transport cannot connect")
        } catch is MobileShellConnectionError {
            Issue.record("trusted route must reach the dial, not the trust rejection")
        } catch {
            // The transport's connect failure (wrapped or not) is expected.
        }
        #expect(factory.requestedRouteIDs == ["loopback"])
    }
}
