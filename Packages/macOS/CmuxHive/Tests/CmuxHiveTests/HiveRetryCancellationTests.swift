import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveRetryCancellationTests {
    @Test(.timeLimit(.minutes(1)))
    func disconnectDuringBackoffDoesNotSendAnotherRequest() async throws {
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list": return ["workspaces": []]
            case "mobile.events.subscribe": return ["stream_id": "events"]
            default: return [:]
            }
        }
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let runtime = HiveSyncRuntime(
            supportedRouteKinds: [.debugLoopback],
            transportFactory: ScriptedHostTransportFactory(transport: transport),
            stackAccessTokenProvider: { "test-stack-token" },
            stackAccessTokenForceRefresher: { "test-stack-token" },
            rpcRequestTimeoutNanoseconds: 5_000_000_000
        )
        let route = try CmxAttachRoute(
            id: "loopback", kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 8000)
        )
        let session = HiveRemoteMacSession(
            runtime: runtime, macDeviceID: "mac-b", displayName: "Test Mac",
            routes: [route],
            retryDelay: { _ in
                started.continuation.yield(())
                await HiveReconnectBackoff(maximumSeconds: 60).delay(attempt: 6)
                finished.continuation.yield(())
            },
            requiresHostIdentity: false
        )
        session.connect()
        do {
            try await transport.waitForMethod("mobile.workspace.list", count: 2)
            await transport.killConnection()
            var starting = started.stream.makeAsyncIterator()
            _ = try #require(await starting.next())
            let requestsBeforeDisconnect = await transport.sentMethods

            await session.disconnect()

            var finishing = finished.stream.makeAsyncIterator()
            _ = try #require(await finishing.next())
            #expect(session.phase == .idle)
            #expect(await transport.sentMethods == requestsBeforeDisconnect)
        } catch {
            await session.disconnect()
            throw error
        }
    }
}
