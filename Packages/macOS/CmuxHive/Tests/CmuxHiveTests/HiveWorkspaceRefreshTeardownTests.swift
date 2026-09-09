import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveWorkspaceRefreshTeardownTests {
    @Test(.timeLimit(.minutes(1)))
    func disconnectWithPendingRefreshAllowsAWorkingSuccessorRefresh() async throws {
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list": return ["workspaces": []]
            case "mobile.events.subscribe": return ["stream_id": "events"]
            default: return [:]
            }
        }
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
            routes: [route], retryDelay: { _ in }, requiresHostIdentity: false
        )
        session.connect()
        do {
            try await transport.waitForMethod("mobile.workspace.list", count: 2)
            try await waitUntil { session.phase == .connected }
            #expect(await session.refreshWorkspaces())
            let before = await transport.sentMethods.filter { $0 == "mobile.workspace.list" }.count
            await transport.dropResponse(to: "mobile.workspace.list", occurrence: before + 1)
            let oldRefresh = Task { await session.refreshWorkspaces() }
            try await transport.waitForMethod("mobile.workspace.list", count: before + 1)

            await session.disconnect()
            #expect(await oldRefresh.value == false)
            #expect(session.reconnectIfNeeded())
            try await waitUntil { session.phase == .connected }
            #expect(await session.refreshWorkspaces())
            #expect(session.phase == .connected)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }
}
