import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func authoritativeStreamDeliversPrimaryGridAndSuppressesRawBytesOnHybridHost() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let collector = AuthoritativeOutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    defer { collector.unmount() }

    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay must settle before live authoritative output"
    )

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 8,
        text: "authoritative-primary"
    ))
    let deliveredGrid = try await pollUntil { collector.renderGrids.count == 1 }
    #expect(deliveredGrid)
    #expect(collector.renderGrids.first?.full == true)
    #expect(collector.renderGrids.first?.plainRows().first == "authoritative-primary")
    #expect(collector.typedGridData == [Data()])

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 8,
        text: "raw-must-not-paint"
    ))
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "after-suppressed-raw"
    ))
    let deliveredFollowingGrid = try await pollUntil { collector.renderGrids.count == 2 }
    #expect(deliveredFollowingGrid)
    #expect(collector.rawChunks.isEmpty)
}

@MainActor
@Test func authoritativeStreamFallsBackToRawBytesForLegacyHost() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.bytes.v1", "terminal.replay.v1"])
    await router.setTerminalFidelity(nil)
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let collector = AuthoritativeOutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    defer { collector.unmount() }

    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the legacy cold replay must settle before live bytes"
    )

    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 0,
        text: "legacy-raw"
    ))
    let deliveredRaw = try await pollUntil { collector.rawChunks.count == 1 }
    try #require(deliveredRaw)
    let rawChunk = try #require(collector.rawChunks.first)
    #expect(String(bytes: rawChunk, encoding: .utf8) == "legacy-raw")
    #expect(collector.renderGrids.isEmpty)
}

@MainActor
@Test("stale same-surface teardown cannot unregister a replacement attachment")
func staleAuthoritativeStreamTerminationPreservesReplacement() async {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    let staleStream = store.authoritativeTerminalOutputStream(surfaceID: surfaceID)
    let staleConsumer = Task { @MainActor in
        for await _ in staleStream {}
    }
    staleConsumer.cancel()

    // A rotation can mount the replacement view before the cancelled view's
    // termination cleanup returns to the main actor. The stale cleanup must be
    // scoped to its own attachment instead of deleting the replacement sink.
    let replacementStream = store.authoritativeTerminalOutputStream(surfaceID: surfaceID)
    await Task.yield()
    await Task.yield()

    #expect(store.terminalByteContinuationsBySurfaceID[surfaceID] != nil)
    #expect(store.authoritativeRenderGridSurfaceIDs.contains(surfaceID))
    withExtendedLifetime(replacementStream) {}
}

@MainActor
@Test("transient status failure preserves negotiated authoritative output")
func transientStatusFailureDoesNotDowngradeAuthoritativeOutput() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    await router.enqueueReplayRenderGridFrames([
        try renderGridFrame(surfaceID: surfaceID, seq: 1, text: "last-good"),
        try renderGridFrame(surfaceID: surfaceID, seq: 6, text: "status-recovery")
    ])
    let collector = AuthoritativeOutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    defer { collector.unmount() }

    try await confirmInitialAuthoritativeGrid(
        store: store,
        router: router,
        collector: collector
    )

    let statusCount = await router.count(of: "mobile.host.status")
    let subscribeCount = await router.count(of: "mobile.events.subscribe")
    await router.failNextHostStatus()
    store.resyncTerminalOutput(
        reason: "test_status_failure",
        restartEventStream: true,
        surfaceIDs: [surfaceID]
    )

    #expect(await router.waitForCount(of: "mobile.host.status", atLeast: statusCount + 1))
    #expect(await router.waitForCount(of: "mobile.events.subscribe", atLeast: subscribeCount + 1))
    #expect(store.supportsAuthoritativeTerminalGrid)

    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 7,
        text: "raw-must-stay-hidden"
    ))
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 7,
        text: "authoritative-survives"
    ))
    let gridDelivered = try await pollUntil {
        collector.renderGrids.contains { $0.plainRows().contains("authoritative-survives") }
    }
    #expect(gridDelivered)
    #expect(collector.rawChunks.isEmpty)
}

@MainActor
private func confirmInitialAuthoritativeGrid(
    store: MobileShellComposite,
    router: LivenessHostRouter,
    collector: AuthoritativeOutputCollector
) async throws {
    let replayStarted = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 1
    }
    #expect(replayStarted)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the first authoritative replay must settle before capability recovery"
    )
    #expect(store.supportsAuthoritativeTerminalGrid)
    let baselineDelivered = try await pollUntil {
        collector.renderGrids.contains { $0.plainRows().contains("last-good") }
    }
    #expect(baselineDelivered)
}

@MainActor
private final class AuthoritativeOutputCollector {
    private(set) var renderGrids: [MobileTerminalRenderGridFrame] = []
    private(set) var typedGridData: [Data] = []
    private(set) var rawChunks: [Data] = []
    private var task: Task<Void, Never>?

    func mount(store: MobileShellComposite, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await chunk in store.authoritativeTerminalOutputStream(surfaceID: surfaceID) {
                if let renderGrid = chunk.renderGrid {
                    self?.renderGrids.append(renderGrid)
                    self?.typedGridData.append(chunk.data)
                } else if !chunk.data.isEmpty {
                    self?.rawChunks.append(chunk.data)
                }
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
            }
        }
    }

    func unmount() {
        task?.cancel()
        task = nil
    }
}
