import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func replayByteFallbackFailsClosedWithoutAuthoritativeScreen() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    await router.enqueueReplayPayload(
        text: "cold-replay",
        sequence: nil,
        anchor: .screen,
        columns: 16,
        rows: 4
    )
    await router.enqueueReplayPayload(
        text: "fallback-replay",
        sequence: nil,
        anchor: .screen,
        columns: 16,
        rows: 4
    )
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("cold-replay") }
    }
    #expect(coldReplayDelivered)
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 3,
        text: "alt",
        columns: 20,
        activeScreen: .alternate
    ))
    let altDelivered = try await pollUntil {
        collector.viewportPolicies.last == .remoteGrid(columns: 20, rows: 4)
    }
    #expect(altDelivered)

    let replayCountAfterAlternate = await router.count(of: "mobile.terminal.replay")
    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: "live-terminal")
    store.requestTerminalReplay(
        surfaceID: "live-terminal",
        replayBarrierToken: replayBarrierToken
    )
    await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterAlternate + 1
    )
    let fallbackReplayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fallback-replay") }
    }
    #expect(fallbackReplayDelivered)
    #expect(
        collector.viewportPolicies.last == .natural,
        "a compatibility fallback without active_screen must not reuse stale alternate-screen sizing"
    )
    #expect(store.terminalActiveScreenBySurfaceID["live-terminal"] == .alternate)
    #expect(store.terminalReplayBarrierTokensBySurfaceID["live-terminal"] == nil)

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 4,
        text: "raw-after-fallback"
    ))
    let rawAfterFallbackDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("raw-after-fallback") }
    }
    #expect(
        !rawAfterFallbackDelivered,
        "byte/snapshot replay fallbacks must not clear alternate-screen raw-byte suppression"
    )

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 10,
        text: "primary-full"
    ))
    let primaryDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("primary-full") }
    }
    #expect(primaryDelivered)
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 10,
        text: "raw-after-primary"
    ))
    let rawAfterPrimaryDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("raw-after-primary") }
    }
    #expect(rawAfterPrimaryDelivered)
    collector.unmount()
}
