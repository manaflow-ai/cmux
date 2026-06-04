import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the terminal output pipeline carved into
/// ``MobileTerminalOutputService``, exercised through the
/// ``MobileShellComposite`` facade against a scripted transport so the
/// connection wiring, event listener, sequence tracking, and replay self-heal
/// run exactly as in production.
@MainActor
@Suite struct MobileTerminalOutputServiceTests {
    @Test func rawBytesEventsDeliverInOrderTrimOverlapAndDropDuplicates() async throws {
        let router = RawBytesOutputRouter()
        let pusher = ShellEventPusher()
        let store = try await connectedStore(router: router, pusher: pusher)
        let collector = ShellTerminalOutputCollector()
        collector.mount(store: store, surfaceID: "live-terminal")
        defer { collector.unmount() }

        // Cold-attach replay (seq 10) must land before live events.
        _ = try await waitForShellRequestCount("mobile.terminal.replay", count: 1, router: router)
        try await waitForCollectedLineCount(1, collector: collector)

        // In-order: seq continues exactly at the delivered end (10).
        try await pusher.push(ShellTestFrames.terminalBytesEventFrame(surfaceID: "live-terminal", seq: 10, text: "AB"))
        try await waitForCollectedLineCount(2, collector: collector)
        // Overlap: first byte was already delivered; only the tail lands.
        try await pusher.push(ShellTestFrames.terminalBytesEventFrame(surfaceID: "live-terminal", seq: 11, text: "BC"))
        try await waitForCollectedLineCount(3, collector: collector)
        // Duplicate: fully covered by the delivered end; dropped.
        try await pusher.push(ShellTestFrames.terminalBytesEventFrame(surfaceID: "live-terminal", seq: 10, text: "ABC"))

        #expect(collector.lines == ["replay-tail", "AB", "C"])
    }

    @Test func rawBytesSequenceGapTriggersReplaySelfHeal() async throws {
        let router = RawBytesOutputRouter()
        let pusher = ShellEventPusher()
        let store = try await connectedStore(router: router, pusher: pusher)
        let collector = ShellTerminalOutputCollector()
        collector.mount(store: store, surfaceID: "live-terminal")
        defer { collector.unmount() }

        _ = try await waitForShellRequestCount("mobile.terminal.replay", count: 1, router: router)
        try await waitForCollectedLineCount(1, collector: collector)

        // Gap: delivered end is 10, next event starts at 20. The gapped bytes
        // must NOT be delivered; a replay catches the surface up instead.
        try await pusher.push(ShellTestFrames.terminalBytesEventFrame(surfaceID: "live-terminal", seq: 20, text: "XYZ"))

        let replays = try await waitForShellRequestCount("mobile.terminal.replay", count: 2, router: router)
        #expect(replays.count == 2)
        try await waitForCollectedLineCount(2, collector: collector)
        #expect(collector.lines == ["replay-tail", "healed-tail"])
        #expect(!collector.lines.contains("XYZ"))
    }

    @Test func renderGridReplayThenLiveFrameAndStaleFrameDropped() async throws {
        let router = RenderGridOutputRouter()
        let pusher = ShellEventPusher()
        let store = try await connectedStore(router: router, pusher: pusher)
        let collector = ShellTerminalOutputCollector()
        collector.mount(store: store, surfaceID: "live-terminal")
        defer { collector.unmount() }

        _ = try await waitForShellRequestCount("mobile.terminal.replay", count: 1, router: router)
        try await waitForCollectedLineCount(1, collector: collector)

        // Live frame ahead of the replay seq is applied.
        try await pusher.push(ShellTestFrames.terminalRenderGridEventFrame(surfaceID: "live-terminal", seq: 6, text: "live"))
        try await waitForCollectedLineCount(2, collector: collector)
        // Stale frame behind the delivered seq is dropped.
        try await pusher.push(ShellTestFrames.terminalRenderGridEventFrame(surfaceID: "live-terminal", seq: 4, text: "stale"))

        let initial = try renderGridPatchText(seq: 5, text: "initial")
        let live = try renderGridPatchText(seq: 6, text: "live")
        #expect(collector.lines == [initial, live])
    }

    @Test func renderGridEventForUnmountedSurfaceIsIgnored() async throws {
        let router = RenderGridOutputRouter()
        let pusher = ShellEventPusher()
        let store = try await connectedStore(router: router, pusher: pusher)
        let collector = ShellTerminalOutputCollector()
        collector.mount(store: store, surfaceID: "live-terminal")
        defer { collector.unmount() }

        _ = try await waitForShellRequestCount("mobile.terminal.replay", count: 1, router: router)
        try await waitForCollectedLineCount(1, collector: collector)

        try await pusher.push(ShellTestFrames.terminalRenderGridEventFrame(surfaceID: "other-terminal", seq: 6, text: "other"))
        try await pusher.push(ShellTestFrames.terminalRenderGridEventFrame(surfaceID: "live-terminal", seq: 6, text: "live"))
        try await waitForCollectedLineCount(2, collector: collector)

        let initial = try renderGridPatchText(seq: 5, text: "initial")
        let live = try renderGridPatchText(seq: 6, text: "live")
        #expect(collector.lines == [initial, live])
    }

    @Test func updateTerminalViewportReturnsEffectiveGridFromHost() async throws {
        let router = RawBytesOutputRouter()
        let pusher = ShellEventPusher()
        let store = try await connectedStore(router: router, pusher: pusher)

        let grid = await store.updateTerminalViewport(surfaceID: "live-terminal", columns: 52, rows: 24)

        #expect(grid?.columns == 48)
        #expect(grid?.rows == 20)
        let report = try #require(try await waitForShellRequestCount("mobile.terminal.viewport", count: 1, router: router).first)
        #expect(report.viewportColumns == 52)
        #expect(report.viewportRows == 24)
        #expect(report.surfaceID == "live-terminal")
        #expect(report.workspaceID == "live-workspace")
    }

    @Test func unmountingOutputStreamClearsViewportPinOnHost() async throws {
        let router = RawBytesOutputRouter()
        let pusher = ShellEventPusher()
        let store = try await connectedStore(router: router, pusher: pusher)
        let collector = ShellTerminalOutputCollector()
        collector.mount(store: store, surfaceID: "live-terminal")
        _ = try await waitForShellRequestCount("mobile.terminal.replay", count: 1, router: router)

        collector.unmount()

        let clear = try #require(try await waitForShellRequestCount("mobile.terminal.viewport", count: 1, router: router).first)
        #expect(clear.clear == true)
        #expect(clear.surfaceID == "live-terminal")
    }

    @Test func reportedViewportSizeRoundTripsThroughService() throws {
        let store = MobileShellComposite.preview()
        let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-main")
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-build")

        store.reportTerminalViewport(
            workspaceID: workspaceID,
            terminalID: terminalID,
            viewportSize: MobileTerminalViewportSize(columns: 52, rows: 24)
        )

        let size = try #require(store.terminalOutput.reportedViewportSize(workspaceID: workspaceID, terminalID: terminalID))
        #expect(size.columns == 52)
        #expect(size.rows == 24)

        store.signOut()
        #expect(store.terminalOutput.reportedViewportSize(workspaceID: workspaceID, terminalID: terminalID) == nil)
    }

    // MARK: - Helpers

    private func connectedStore(
        router: any ShellTransportRouter,
        pusher: ShellEventPusher
    ) async throws -> MobileShellComposite {
        let runtime = TestShellSyncRuntime(
            transportFactory: ShellRouterTransportFactory(router: router, pusher: pusher)
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let connected = await store.connectPairingURL(try ShellTestFrames.attachURL(for: ShellTestFrames.liveTicket()))
        try #require(connected)
        _ = try await waitForShellRequestCount("mobile.events.subscribe", count: 1, router: router)
        return store
    }

    private func renderGridPatchText(seq: UInt64, text: String) throws -> String {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "live-terminal",
            stateSeq: seq,
            columns: 16,
            rows: 4,
            text: text
        )
        return try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    }
}

/// Scripted Mac host advertising the raw-bytes terminal fidelity. Replays
/// return a raw tail at seq 10 first, then a healed tail at seq 23.
actor RawBytesOutputRouter: ShellTransportRouter {
    private var requests: [RecordedShellRPCRequest] = []
    private var replayCount = 0

    func record(_ request: RecordedShellRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedShellRPCRequest] {
        requests
    }

    func response(for request: RecordedShellRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try ShellTestFrames.workspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try ShellTestFrames.hostStatusFrame(renderGrid: false)
        case "mobile.events.subscribe":
            return try ShellTestFrames.resultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            replayCount += 1
            if replayCount == 1 {
                return try ShellTestFrames.terminalReplayFrame(surfaceID: "live-terminal", seq: 10, rawText: "replay-tail")
            }
            return try ShellTestFrames.terminalReplayFrame(surfaceID: "live-terminal", seq: 23, rawText: "healed-tail")
        case "mobile.terminal.viewport":
            if request.clear == true {
                return try ShellTestFrames.resultFrame(result: ["cleared": true])
            }
            return try ShellTestFrames.resultFrame(result: ["columns": 48, "rows": 20])
        default:
            return try ShellTestFrames.errorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

/// Scripted Mac host advertising the render-grid terminal fidelity. Replay
/// returns a render-grid frame at seq 5.
actor RenderGridOutputRouter: ShellTransportRouter {
    private var requests: [RecordedShellRPCRequest] = []

    func record(_ request: RecordedShellRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedShellRPCRequest] {
        requests
    }

    func response(for request: RecordedShellRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try ShellTestFrames.workspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try ShellTestFrames.hostStatusFrame(renderGrid: true)
        case "mobile.events.subscribe":
            return try ShellTestFrames.resultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            return try ShellTestFrames.terminalReplayFrame(
                surfaceID: "live-terminal",
                seq: 5,
                rawText: "unused-tail",
                renderGridText: "initial"
            )
        case "mobile.terminal.viewport":
            return try ShellTestFrames.resultFrame(result: ["cleared": true])
        default:
            return try ShellTestFrames.errorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}
