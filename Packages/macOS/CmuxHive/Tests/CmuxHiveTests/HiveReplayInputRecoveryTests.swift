import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxHive

@MainActor
struct HiveReplayInputRecoveryTests {
    @Test(.timeLimit(.minutes(1)))
    func successfulReplayDrainsInputQueuedDuringInitialAttach() async throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "term-1", stateSeq: 1, columns: 20, rows: 5, full: true,
            rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "ready")]
        )
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list": return ["workspaces": []]
            case "mobile.events.subscribe": return ["stream_id": "events"]
            case "mobile.terminal.replay":
                return [
                    "workspace_id": "ws-1", "surface_id": "term-1",
                    "render_grid": (try? frame.jsonObject()) ?? [:],
                ]
            default: return [:]
            }
        }
        await transport.holdResponse(to: "mobile.terminal.replay", occurrence: 1)
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
        try await waitUntil { session.phase == .connected }
        let client = try #require(session.client)
        let terminal = HiveRemoteTerminalSession(
            client: client, workspaceID: "ws-1", terminalID: "term-1",
            retryDelay: { _ in }
        )
        terminal.attach()
        try await transport.waitForMethod("mobile.terminal.replay")
        try #require(terminal.phase == .attaching)
        terminal.send(text: "queued-during-attach")
        await transport.releaseResponse(to: "mobile.terminal.replay", occurrence: 1)
        try await waitUntil { terminal.phase == .live }

        try await transport.waitForMethod("mobile.terminal.input")
        #expect(await transport.sentInputTexts == ["queued-during-attach"])
        terminal.detach()
        await session.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulReplayDrainsInputQueuedDuringRecovery() async throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "term-1", stateSeq: 1, columns: 20, rows: 5, full: true,
            rowSpans: [.init(row: 0, column: 0, styleID: 0, text: "ready")]
        )
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list": return ["workspaces": []]
            case "mobile.events.subscribe": return ["stream_id": "events"]
            case "mobile.terminal.replay":
                return [
                    "workspace_id": "ws-1", "surface_id": "term-1",
                    "render_grid": (try? frame.jsonObject()) ?? [:],
                ]
            default: return [:]
            }
        }
        await transport.failResponse(to: "mobile.terminal.replay", occurrence: 2)
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
        try await waitUntil { session.phase == .connected }
        let client = try #require(session.client)
        let recoveryStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let recoveryRelease = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { recoveryRelease.continuation.finish() }
        let terminal = HiveRemoteTerminalSession(
            client: client, workspaceID: "ws-1", terminalID: "term-1",
            retryDelay: { _ in
                recoveryStarted.continuation.yield(())
                for await _ in recoveryRelease.stream { break }
            }
        )
        terminal.attach()
        do {
            try await waitUntil { terminal.phase == .live }
            terminal.refreshReplay()
            var started = recoveryStarted.stream.makeAsyncIterator()
            _ = try #require(await started.next())
            try #require(terminal.phase == .reattaching)
            terminal.send(text: "queued-during-recovery")
            recoveryRelease.continuation.finish()
            try await waitUntil { terminal.phase == .live }

            try await transport.waitForMethod("mobile.terminal.input")
            #expect(await transport.sentInputTexts == ["queued-during-recovery"])
        } catch {
            terminal.detach()
            await session.disconnect()
            throw error
        }
        terminal.detach()
        await session.disconnect()
    }
}
