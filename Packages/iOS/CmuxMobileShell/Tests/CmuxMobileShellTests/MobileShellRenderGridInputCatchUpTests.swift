import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func renderGridInputAcksDoNotReplayWhileWaitingForCatchUp() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    await store.submitTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 2 }
    #expect(inputSent)

    let replayRequested = try await pollUntil(attempts: 50) {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(
        !replayRequested,
        "back-to-back input ACKs can legitimately run ahead of render-grid delivery; they must not force a full replay while waiting for the target frame"
    )
    collector.unmount()
}

@MainActor
@Test func renderGridInputPendingSequenceSkipsOlderFramesUntilTargetArrives() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    await store.submitTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 2 }
    #expect(inputSent)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 99,
        text: "before-ack"
    ))
    let staleFrameDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("before-ack") }
    }
    #expect(
        !staleFrameDelivered,
        "once input ACKs establish a newer target sequence, an older render-grid cursor frame must not be presented and then corrected later"
    )

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 100,
        text: "at-ack"
    ))
    let targetFrameDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("at-ack") }
    }
    #expect(targetFrameDelivered, "the first frame at the pending input sequence must render immediately")
    collector.unmount()
}
