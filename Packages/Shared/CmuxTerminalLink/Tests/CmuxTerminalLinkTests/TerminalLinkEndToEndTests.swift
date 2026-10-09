import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import CmuxTerminalLink
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing

/// The phone's `LinkTerminalByteSource` against a real B5 `MobileHost` over
/// CmuxLink loopback and lossy carriers (c1-terminal-rpc.md section 11).
@Suite("terminal link end to end")
struct TerminalLinkEndToEndTests {
    static func recorded(_ attachment: ScriptedAttachment) async throws -> String {
        try await within { try #require(await attachment.recorded.next()) }
    }

    static func waitFor(_ attachment: ScriptedAttachment, _ entry: String) async throws {
        try await within {
            while let next = await attachment.recorded.next() {
                if next == entry { return }
            }
            throw TimeoutError()
        }
    }

    static func telemetry(_ source: LinkTerminalByteSource,
                          until condition: @escaping @Sendable (TerminalLatencyReport) -> Bool) async throws -> TerminalLatencyReport {
        let stream = await source.telemetry()
        return try await within {
            for await report in stream where condition(report) { return report }
            throw TimeoutError()
        }
    }

    // MARK: Attach

    @Test func attachGivesTheGridThenAReadyKeyframeThenLiveBytes() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        #expect(attachment.request.terminal == "term_x1")
        #expect(attachment.request.visible && attachment.request.counts)
        #expect(attachment.request.viewport == CmuxMobileWire.TerminalViewport(cols: 54, rows: 44))
        #expect(attachment.request.snapshotVersions == [1])
        #expect(attachment.request.viewer.install == TerminalHarness.install)
        // Smallest of the Mac's 150 x 42 and the phone's 54 x 44, component-wise.
        let grid = try await log.grid()
        #expect(grid.cols == 54 && grid.rows == 42 && grid.generation == 7)
        attachment.ready(offset: 1000)
        attachment.bytes("hello", endingAt: 1005)
        attachment.emit(.title("vim", cwd: "/src"))
        let ready = try await log.frame()
        #expect(ready.kind == .snapshotReady && ready.offset == 1000)
        let bytes = try await log.frame()
        #expect(bytes.kind == .bytes && bytes.payload == Data("hello".utf8) && bytes.offset == 1005)
        let title = try await log.next { event -> String? in
            if case .title(let title) = event, title == "vim" { return title }
            return nil
        }
        #expect(title == "vim")
    }

    @Test func aTerminalOutsideTheHostsTreeEndsWithAReason() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let other = LinkTerminalByteSource(terminal: "term_zz9", client: h.client)
        let log = EventLog(try await other.open(TerminalViewport(cols: 40, rows: 20, visible: true)))
        #expect(try await log.closed() == TerminalLinkFailure.notFound.defaultText)
        #expect(await other.lastFailure() == .notFound)
    }

    // MARK: Input

    @Test func inputArrivesInOrderOnALoopbackLink() async throws {
        try await Self.typesInOrder(TerminalHarness())
    }

    @Test func inputArrivesInOrderOnALossyJitteryLink() async throws {
        try await Self.typesInOrder(TerminalHarness(conditions: NetworkConditions(latency: .milliseconds(2),
                                                                                    jitter: .milliseconds(3), loss: 0.2)))
    }

    static func typesInOrder(_ h: TerminalHarness) async throws {
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 0)
        _ = try await log.frame(.snapshotReady)
        let keys = (0..<300).map { "k\($0 % 10)" }
        for (index, key) in keys.enumerated() {
            try await h.source.send(Data(key.utf8))
            // Viewport traffic on the same channel never reorders input.
            if index % 50 == 0 {
                await h.source.viewportChanged(TerminalViewport(cols: 54 + index / 50, rows: 44, visible: true))
            }
        }
        try await within {
            while await attachment.inputs.count < keys.count { _ = await attachment.recorded.next() }
        }
        #expect(await attachment.typed == keys.joined())
        #expect(await attachment.inputs.allSatisfy { $0.kind == .bytes })
    }

    @Test func inputWithoutAnAttachedChannelThrowsInsteadOfQueueing() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        await #expect(throws: TerminalLinkError.notConnected) {
            try await h.source.send(Data("x".utf8))
        }
    }

    // MARK: Flood

    @Test func aRendererThatFallsBehindCostsOneSnapshotNotAnUnboundedQueue() async throws {
        let h = await TerminalHarness(options: TerminalLinkOptions(window: 1024 * 1024, queueBudget: 4096))
        defer { Task { await h.shutdown() } }
        // Open without reading: the renderer is busy.
        let stream = try await h.source.open(TerminalViewport(cols: 54, rows: 44, visible: true))
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 0)
        for index in 1...40 {
            attachment.bytes(String(repeating: "a", count: 1000), endingAt: UInt64(index * 1000))
        }
        try await Self.waitFor(attachment, "snapshot:gap")
        #expect(await attachment.snapshotRequests.first?.requestID.hasPrefix("c1-resync") == true)
        attachment.ready(offset: 50_000)
        // The renderer catches up: no stale bytes, the fresh READY first.
        let firstFrame = try await within { () -> TerminalFrame? in
            for await event in stream {
                if case .frame(let frame) = event { return frame }
            }
            return nil
        }
        #expect(firstFrame?.kind == .snapshotReady)
        #expect(firstFrame?.offset == 50_000)
        let report = try await Self.telemetry(h.source) { $0.phoneOverflows >= 1 }
        #expect(report.phoneOverflows == 1)
    }

    // MARK: Resize and presence

    @Test func aHiddenPhoneStopsCountingAndTheKeyboardNeverResizes() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open(cols: 54, rows: 44)
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 0)
        let first = try await log.grid()
        #expect(first.cols == 54 && first.rows == 42)
        // Keyboard shown: the renderer reports the same full-height grid; nothing goes out.
        await h.source.viewportChanged(TerminalViewport(cols: 54, rows: 44, visible: true))
        // Background: presence only, the grid goes back to the Mac's.
        await h.source.viewportChanged(TerminalViewport(cols: 54, rows: 44, visible: false))
        #expect(try await Self.recorded(attachment) == "presence:false")
        let hidden = try await log.grid()
        #expect(hidden.cols == 150 && hidden.rows == 42 && hidden.generation == 8)
        // Rotated while hidden: no report until the phone is back.
        await h.source.viewportChanged(TerminalViewport(cols: 100, rows: 30, visible: false))
        await h.source.viewportChanged(TerminalViewport(cols: 100, rows: 30, visible: true))
        #expect(try await Self.recorded(attachment) == "viewport:100x30")
        #expect(try await Self.recorded(attachment) == "presence:true")
        let back = try await log.grid()
        #expect(back.cols == 100 && back.rows == 30 && back.generation == 9)
        let ready = try await log.frame(.snapshotReady)
        #expect(ready.generation == 9)
    }

    // MARK: Reconnect

    @Test func aDroppedTransportResumesWithoutReattaching() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 1000)
        _ = try await log.frame(.snapshotReady)
        await h.network.dropAll()
        attachment.bytes("b", endingAt: 1001)
        let bytes = try await log.frame(.bytes)
        #expect(bytes.payload == Data("b".utf8))
        try await h.source.send(Data("x".utf8))
        try await Self.waitFor(attachment, "input")
        #expect(await attachment.typed == "x")
        #expect(await h.daemon.attachments.count == 0)
        #expect(await h.source.telemetry().first { _ in true }?.reattaches == 0)
    }

    @Test func aNewLinkEpochReattachesAndRestoresFromAKeyframe() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let first = try await h.nextAttachment()
        first.ready(offset: 1000)
        _ = try await log.frame(.snapshotReady)
        await h.restartHost()
        let second = try await h.nextAttachment()
        #expect(second.request.terminal == "term_x1")
        second.ready(offset: 5000)
        let ready = try await log.frame(.snapshotReady)
        #expect(ready.offset == 5000)
        try await h.source.send(Data("y".utf8))
        try await Self.waitFor(second, "input")
        #expect(await second.typed == "y")
        let report = try await Self.telemetry(h.source) { $0.reattaches >= 1 }
        #expect(report.reattaches >= 1)
        #expect(await h.client.currentGeneration >= 2)
    }

    // MARK: Ends

    @Test func aKickEndsTheStreamWithoutReattaching() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 0)
        attachment.emit(.kicked(by: "u_bob", byName: "Bob"))
        let name = try await log.next { event -> String? in
            if case .kicked(let name) = event { return name }
            return nil
        }
        #expect(name == "Bob")
        if let after = await log.events.next() { Issue.record("stream continued after a kick: \(after)") }
        #expect(await h.daemon.attachments.count == 0)
    }

    @Test func anExitEndsTheStreamWithTheOwnersReason() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 0)
        attachment.emit(.exited(code: 0, signal: nil))
        attachment.emit(.closed)
        #expect(try await log.closed() == TerminalLinkFailure.exited.defaultText)
    }
}
