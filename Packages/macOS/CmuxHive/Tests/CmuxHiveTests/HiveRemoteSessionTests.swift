import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxHive

/// A scripted `MobileSyncRuntime` over the fake host transport.
private func makeRuntime(transport: ScriptedHostTransport) -> HiveSyncRuntime {
    HiveSyncRuntime(
        supportedRouteKinds: [.tailscale, .debugLoopback],
        transportFactory: ScriptedHostTransportFactory(transport: transport),
        stackAccessTokenProvider: { "test-stack-token" },
        stackAccessTokenForceRefresher: { "test-stack-token" },
        rpcRequestTimeoutNanoseconds: 5_000_000_000
    )
}

private func tailscaleRoute() throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.0.9", port: 8000),
        priority: 10
    )
}

private func workspaceListResult() -> [String: Any] {
    [
        "workspaces": [
            [
                "id": "ws-1",
                "title": "repo",
                "is_selected": true,
                "terminals": [
                    ["id": "term-1", "title": "zsh", "is_focused": true],
                    ["id": "term-2", "title": "logs", "is_focused": false],
                ],
            ],
            [
                "id": "ws-2",
                "title": "notes",
                "is_selected": false,
                "terminals": [],
            ],
        ]
    ]
}

/// A full render-grid frame pre-encoded to a JSON string so `@Sendable`
/// handler closures can capture it (`[String: Any]` is not Sendable).
private func fullFrameJSONString(text: String, stateSeq: UInt64) throws -> String {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "term-1",
        stateSeq: stateSeq,
        columns: 20,
        rows: 5,
        full: true,
        rowSpans: [.init(row: 0, column: 0, styleID: 0, text: text)]
    )
    let data = try JSONSerialization.data(withJSONObject: frame.jsonObject())
    return String(decoding: data, as: UTF8.self)
}

/// Decode a pre-encoded JSON object string back into a dictionary inside the
/// handler closure.
private func jsonObject(_ string: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]) ?? [:]
}

@Suite struct HiveRemoteSessionTests {
    @MainActor
    @Test func connectFetchesWorkspacesAndTracksUpdates() async throws {
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list":
                return workspaceListResult()
            case "mobile.events.subscribe":
                return ["stream_id": "s", "topics": ["workspace.updated"], "already_subscribed": false]
            default:
                return [:]
            }
        }
        let session = HiveRemoteMacSession(
            runtime: makeRuntime(transport: transport),
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [try tailscaleRoute()],
            retryDelay: { _ in }
        )
        session.connect()
        await transport.waitForMethod("mobile.events.subscribe")
        // The event loop refreshes once after subscribing.
        await transport.waitForMethod("mobile.workspace.list", count: 2)
        try await waitUntil { session.phase == .connected && session.workspaces.count == 2 }

        #expect(session.workspaces.first?.id == "ws-1")
        #expect(session.workspaces.first?.terminals.count == 2)
        #expect(session.workspaces.first?.defaultTerminal?.id == "term-1")

        // A workspace.updated push triggers a list refresh.
        await transport.pushEvent(topic: "workspace.updated", payload: [:])
        await transport.waitForMethod("mobile.workspace.list", count: 3)

        await session.disconnect()
    }

    @MainActor
    @Test func terminalSessionRepliesReplayThenAppliesEventsAndSendsInput() async throws {
        let replayFrame = try fullFrameJSONString(text: "hello from mac b", stateSeq: 1)
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list":
                return workspaceListResult()
            case "mobile.events.subscribe":
                return ["stream_id": "s", "topics": ["terminal.render_grid"], "already_subscribed": false]
            case "mobile.terminal.replay":
                return [
                    "workspace_id": "ws-1",
                    "surface_id": "term-1",
                    "seq": 1,
                    "columns": 20,
                    "rows": 5,
                    "render_grid": jsonObject(replayFrame),
                ]
            case "mobile.terminal.input":
                return ["workspace_id": "ws-1", "surface_id": "term-1", "queued": false]
            default:
                return [:]
            }
        }
        let runtime = makeRuntime(transport: transport)
        let macSession = HiveRemoteMacSession(
            runtime: runtime,
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [try tailscaleRoute()],
            retryDelay: { _ in }
        )
        macSession.connect()
        try await waitUntil { macSession.phase == .connected }
        let client = try #require(macSession.client)

        let terminal = HiveRemoteTerminalSession(
            client: client,
            workspaceID: "ws-1",
            terminalID: "term-1",
            retryDelay: { _ in }
        )
        terminal.attach()
        try await waitUntil { terminal.phase == .live && terminal.grid.hasContent }
        #expect(terminal.grid.plainRow(0) == "hello from mac b")

        // A delta push for this surface updates the grid; another surface's
        // frame is ignored.
        let delta = try MobileTerminalRenderGridFrame(
            surfaceID: "term-1",
            stateSeq: 2,
            columns: 20,
            rows: 5,
            full: false,
            rowSpans: [.init(row: 1, column: 0, styleID: 0, text: "second line")]
        )
        await transport.pushEvent(topic: "terminal.render_grid", payload: try delta.jsonObject())
        let foreign = try MobileTerminalRenderGridFrame(
            surfaceID: "term-9",
            stateSeq: 9,
            columns: 20,
            rows: 5,
            full: false,
            rowSpans: [.init(row: 2, column: 0, styleID: 0, text: "not ours")]
        )
        await transport.pushEvent(topic: "terminal.render_grid", payload: try foreign.jsonObject())
        try await waitUntil { terminal.grid.plainRow(1) == "second line" }
        #expect(terminal.grid.plainRow(2) == "")

        // Typing reaches the host's PTY via terminal.input.
        terminal.send(text: "ls\r")
        await transport.waitForMethod("mobile.terminal.input")
        let inputs = await transport.sentInputTexts
        #expect(inputs == ["ls\r"])

        terminal.detach()
        await macSession.disconnect()
    }

    @MainActor
    @Test func terminalSessionReattachesAfterConnectionDrop() async throws {
        let replayFrame = try fullFrameJSONString(text: "first attach", stateSeq: 1)
        let secondFrame = try fullFrameJSONString(text: "after recovery", stateSeq: 5)
        let transport = ScriptedHostTransport { method, _ in
            switch method {
            case "mobile.workspace.list":
                return workspaceListResult()
            case "mobile.events.subscribe":
                return ["stream_id": "s", "topics": ["terminal.render_grid"], "already_subscribed": false]
            case "mobile.terminal.replay":
                return [
                    "workspace_id": "ws-1",
                    "surface_id": "term-1",
                    "seq": 1,
                    "render_grid": jsonObject(replayFrame),
                ]
            default:
                return [:]
            }
        }
        let runtime = makeRuntime(transport: transport)
        let macSession = HiveRemoteMacSession(
            runtime: runtime,
            macDeviceID: "mac-b",
            displayName: "Studio",
            routes: [try tailscaleRoute()],
            retryDelay: { _ in }
        )
        macSession.connect()
        try await waitUntil { macSession.phase == .connected }
        let client = try #require(macSession.client)
        let terminal = HiveRemoteTerminalSession(
            client: client,
            workspaceID: "ws-1",
            terminalID: "term-1",
            retryDelay: { _ in }
        )
        terminal.attach()
        try await waitUntil { terminal.phase == .live }
        let replaysBeforeDrop = await transport.sentMethods.filter { $0 == "mobile.terminal.replay" }.count

        // Drop the connection host-side: the reader sees EOF, the client
        // tears down, and the attach loop re-subscribes + re-replays over a
        // freshly connected transport.
        await transport.killConnection()
        await transport.waitForMethod("mobile.terminal.replay", count: replaysBeforeDrop + 1)
        try await waitUntil { terminal.phase == .live }
        await transport.pushEvent(topic: "terminal.render_grid", payload: jsonObject(secondFrame))
        try await waitUntil { terminal.grid.plainRow(0) == "after recovery" }

        terminal.detach()
        await macSession.disconnect()
    }
}

/// Await a main-actor condition with a bounded deadline, yielding between
/// checks (no fixed sleeps; the deadline only bounds a hung test).
@MainActor
func waitUntil(
    timeoutNanoseconds: UInt64 = 10_000_000_000,
    _ condition: @MainActor () -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
            Issue.record("waitUntil timed out")
            return
        }
        await Task.yield()
    }
}
