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
    let firstGrid = try #require(collector.renderGrids.first)
    #expect(firstGrid.full == true)
    #expect(firstGrid.plainRows().first == "authoritative-primary")
    #expect(!collector.typedGridData[0].isEmpty)
    #expect(collector.typedGridData == [firstGrid.vtReplacementBytes()])

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
