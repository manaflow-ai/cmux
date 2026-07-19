import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCAuthScopeTests {
    @Test func sharedTokenGateDoesNotJoinDifferentScopes() async throws {
        let gate = RPCStackTokenGate()
        let provider = CancellationIgnoringTokenProvider()
        let firstScope = MobileRPCAuthScope()
        let secondScope = MobileRPCAuthScope()
        let first = Task {
            try await gate.token(scope: firstScope, timeoutNanoseconds: 30_000_000_000) {
                try await provider.token()
            }
        }
        await provider.waitUntilStartCount(1)
        let second = Task {
            try await gate.token(scope: secondScope, timeoutNanoseconds: 30_000_000_000) {
                try await provider.token()
            }
        }
        await provider.waitUntilStartCount(2)

        #expect(await provider.startCount == 2)
        await provider.release()
        #expect(try await first.value == "released-token")
        #expect(try await second.value == "released-token")
    }

    @Test func invalidatedScopeCannotReuseItsOldTokenTask() async throws {
        let gate = RPCStackTokenGate()
        let provider = CancellationIgnoringTokenProvider()
        let scope = MobileRPCAuthScope()
        let first = Task {
            try await gate.token(scope: scope, timeoutNanoseconds: 30_000_000_000) {
                try await provider.token()
            }
        }
        await provider.waitUntilStartCount(1)
        await gate.invalidate(scope: scope)
        let second = Task {
            try await gate.token(scope: scope, timeoutNanoseconds: 30_000_000_000) {
                try await provider.token()
            }
        }
        await provider.waitUntilStartCount(2)

        #expect(await provider.startCount == 2)
        await provider.release()
        _ = try? await first.value
        #expect(try await second.value == "released-token")
    }

    @Test(arguments: ["workspace.list", "mobile.host.status"])
    func invalidatedAuthScopeBeforeSessionEnqueueSendsNothing(method: String) async throws {
        let validation = ScopedRPCValidationGate(blockedCall: 3)
        let transport = ImmediateResponseRecordingTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58_465)
        let runtime = TestMobileSyncRuntime(
            transportFactory: FixedTransportFactory(transport: transport),
            stackAccessToken: "scoped-token",
            stackAccessTokenForStatus: "status-token"
        )
        let client = MobileCoreRPCClient.testClient(
            runtime: runtime,
            route: route,
            ticket: try ticket(route: route),
            allowsStackAuthFallback: true,
            authScope: MobileRPCAuthScope(),
            authScopeValidator: { await validation.validate() }
        )
        let request = try MobileCoreRPCClient.requestData(method: method)
        let send = Task { try await client.sendRequest(request) }
        await validation.waitUntilBlocked()
        await validation.invalidateAndRelease()

        do {
            _ = try await send.value
            Issue.record("Expected invalid auth scope to cancel before enqueue")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func invalidatedAuthScopeWhileConnectionEstablishesSendsNothing() async throws {
        let validation = ScopedRPCValidationGate(blockedCall: .max)
        let transport = ReleasableConnectTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58_465)
        let client = MobileCoreRPCClient.testClient(
            runtime: TestMobileSyncRuntime(
                transportFactory: ReleasableConnectTransportFactory(transport: transport),
                stackAccessToken: "scoped-token"
            ),
            route: route,
            ticket: try ticket(route: route),
            allowsStackAuthFallback: true,
            authScope: MobileRPCAuthScope(),
            authScopeValidator: { await validation.validate() }
        )
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let send = Task { try await client.sendRequest(request) }
        #expect(await transport.waitUntilConnectStarted())

        await validation.invalidateAndRelease()
        await transport.releaseConnect()

        do {
            _ = try await send.value
            Issue.record("Expected invalid auth scope to cancel before enqueue")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(try await transport.sentRequests().isEmpty)
    }

    @Test func revokedManualTrustBeforeSessionEnqueueSendsNothing() async throws {
        let trust = ScopedRPCValidationGate(blockedCall: 3)
        let transport = ImmediateResponseRecordingTransport()
        let route = try hostPortRoute(kind: .manualHost, host: "192.168.1.77", port: 58_465)
        let client = MobileCoreRPCClient.testClient(
            runtime: TestMobileSyncRuntime(
                transportFactory: FixedTransportFactory(transport: transport),
                supportedRouteKinds: [.manualHost],
                stackAccessToken: "manual-token"
            ),
            route: route,
            ticket: try ticket(route: route),
            allowsStackAuthFallback: true,
            manualHostStackAuthTrustProvider: { await trust.validate() },
            authScope: MobileRPCAuthScope()
        )
        let request = try MobileCoreRPCClient.requestData(method: "workspace.list")
        let send = Task { try await client.sendRequest(request) }
        await trust.waitUntilBlocked()
        await trust.invalidateAndRelease()

        do {
            _ = try await send.value
            Issue.record("Expected revoked trust to block session enqueue")
        } catch let error as MobileShellConnectionError {
            guard case .insecureManualRoute = error else {
                Issue.record("Expected insecureManualRoute, got \(error)")
                return
            }
        }
        #expect(try await transport.sentRequests().isEmpty)
    }

    private func ticket(route: CmxAttachRoute) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil,
            authToken: nil
        )
    }
}
