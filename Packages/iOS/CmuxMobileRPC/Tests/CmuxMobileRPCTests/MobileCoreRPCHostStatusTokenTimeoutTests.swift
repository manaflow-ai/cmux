import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCHostStatusTokenTimeoutTests {
    @Test func hostStatusProbeDoesNotTouchSlowStackTokenProvider() async throws {
        let tokenProvider = FirstCallHangsTokenProvider()
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59128)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenProvider: {
                try await tokenProvider.token()
            },
            rpcRequestTimeoutNanoseconds: 60 * 1_000_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let status = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "status"
        )

        let statusTask = Task {
            try await client.sendRequest(status, timeoutNanoseconds: 60 * 1_000_000_000)
        }
        let statusSent = try await transport.waitForSentRequestCount(1)
        #expect(statusSent.first?.method == "mobile.host.status")
        #expect(statusSent.first?.stackAccessToken == nil)
        #expect(await tokenProvider.startCount == 0)
        statusTask.cancel()
        await transport.releaseFirstSend()
        _ = try? await statusTask.value
    }

    @Test func hostStatusProbeTimeoutCoversStatusStackTokenFallback() async throws {
        let tokenStarted = AsyncFlag()
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59130)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenForStatusProvider: {
                await tokenStarted.set()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return Task.isCancelled ? nil : "late-status-token"
            },
            rpcRequestTimeoutNanoseconds: 10_000_000
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        let status = try MobileCoreRPCClient.requestData(
            method: "mobile.host.status",
            params: [:],
            id: "status"
        )

        do {
            _ = try await client.sendRequest(status)
            Issue.record("Expected slow status Stack token fallback to be bounded by the RPC timeout")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected requestTimedOut, got \(error)")
        }

        #expect(await tokenStarted.isSet())
        #expect(try await transport.sentRequests().isEmpty)
    }
}
