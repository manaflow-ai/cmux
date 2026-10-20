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
        let tokenProvider = ReleasableStatusTokenProvider()
        let transport = QueuedCancellationProbeTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59130)
        let runtime = TestMobileSyncRuntime(
            transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
            stackAccessTokenForStatusProvider: {
                await tokenProvider.token()
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

        #expect(await tokenProvider.didStart())
        #expect(try await transport.sentRequests().isEmpty)
        await tokenProvider.release()
    }

    @Test func separateHostStatusRequestDoesNotReuseImplicitAuthorizationState() async throws {
        let statusTokenProviderStarted = AsyncFlag()
        let transport = ImmediateResponseRecordingTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59131)
        let runtime = TestMobileSyncRuntime(
            transportFactory: ImmediateResponseRecordingTransportFactory(transport: transport),
            stackAccessTokenProvider: { "workspace-token" },
            stackAccessTokenForStatusProvider: {
                await statusTokenProviderStarted.set()
                return "status-token"
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

        _ = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "workspace.list",
                params: ["workspace_id": "workspace-main"],
                id: "workspace"
            )
        )
        _ = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.host.status",
                id: "status"
            )
        )

        let sent = try await transport.sentRequests()
        #expect(sent.map(\.method) == ["workspace.list", "mobile.host.status"])
        #expect(sent.map(\.stackAccessToken) == ["workspace-token", "status-token"])
        #expect(await statusTokenProviderStarted.isSet())
    }

    @Test func explicitHostStatusUsesTheSuccessfulAuthorizedRequestToken() async throws {
        let statusTokenProviderStarted = AsyncFlag()
        let transport = ImmediateResponseRecordingTransport()
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59132)
        let runtime = TestMobileSyncRuntime(
            transportFactory: ImmediateResponseRecordingTransportFactory(transport: transport),
            stackAccessTokenProvider: { "workspace-token" },
            stackAccessTokenForStatusProvider: {
                await statusTokenProviderStarted.set()
                return "different-status-token"
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

        _ = try await client.sendRequestAndAuthenticatedHostStatus(
            MobileCoreRPCClient.requestData(
                method: "workspace.list",
                params: ["workspace_id": "workspace-main"],
                id: "workspace"
            ),
            hostStatusTimeoutNanoseconds: { 60 * 1_000_000_000 }
        )

        let sent = try await transport.sentRequests()
        #expect(sent.map(\.method) == ["workspace.list", "mobile.host.status"])
        #expect(sent.map(\.stackAccessToken) == ["workspace-token", "workspace-token"])
        #expect(!(await statusTokenProviderStarted.isSet()))
    }
}

private actor ReleasableStatusTokenProvider {
    private var continuation: CheckedContinuation<String?, Never>?
    private var started = false

    func token() async -> String? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func didStart() -> Bool {
        started
    }

    func release() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

private actor ImmediateResponseRecordingTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var queuedResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
        guard !isClosed else { return nil }
        if !queuedResponses.isEmpty {
            return queuedResponses.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
        for payload in payloads {
            let request = try recordedRPCRequest(from: payload)
            let response = try JSONSerialization.data(withJSONObject: [
                "id": request.id ?? "",
                "ok": true,
                "result": ["status": "ok"],
            ])
            let frame = try MobileSyncFrameCodec.encodeFrame(response)
            if let waiter = receiveWaiters.first {
                receiveWaiters.removeFirst()
                waiter.resume(returning: frame)
            } else {
                queuedResponses.append(frame)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }
}

private struct ImmediateResponseRecordingTransportFactory: CmxByteTransportFactory {
    let transport: ImmediateResponseRecordingTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
