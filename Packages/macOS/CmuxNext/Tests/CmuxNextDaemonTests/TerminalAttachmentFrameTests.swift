import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Attach frames to channel events (attach-frames-v1, p05-ipc-097): output reaches the view as a slice of the
/// read buffer, slices join only by range, offsets are checked, and a gap asks for a fresh READY.
struct TerminalAttachmentFrameTests {
    private static let surface = SurfaceID(rawValue: 3)
    private let wire = WireDecoder(recorder: nil)

    // MARK: Zero copies

    @Test func outputReachesTheViewAsASliceOfTheReadBuffer() async throws {
        var builder = FrameBuilder()
        builder.replay(offset: 100, data: "replayed-screen-bytes")
        let first = Self.bytes(0x61, count: 8192)
        let second = Self.bytes(0x62, count: 8192)
        builder.add(.output, offset: 100, payload: first)
        builder.add(.output, offset: 8292, payload: second)
        let (buffer, frames) = try builder.frames()
        let events = await run(frames)

        try #require(events.count == 3)
        #expect(events[1] == .output(Data(first), colors: nil))
        #expect(events[2] == .output(Data(second), colors: nil))
        let start = Self.address(buffer.bytes)
        let bufferRange = start ..< start + UInt(buffer.bytes.count)
        for event in events.dropFirst() {
            guard case .output(let data, _) = event else { Issue.record("not output: \(event)"); continue }
            // The bytes the view gets lie in the read buffer: nothing copied them out.
            #expect(bufferRange.contains(Self.address(data)))
        }
    }

    @Test func slicesJoinOnlyByRangeInOneBufferAndNeverAcrossAnotherEvent() async throws {
        let bytes = Data(Self.bytes(0x41, count: 300))
        let buffer = TerminalReadBuffer(bytes)
        func span(_ range: Range<Int>, at offset: UInt64) throws -> TerminalOutputSpan {
            TerminalOutputSpan(offset: offset, bytes: try #require(TerminalFrameBytes(buffer: buffer, range: range)))
        }
        let queue = TerminalEventQueue(recorder: nil)
        queue.push(try span(0 ..< 100, at: 0))
        queue.push(try span(100 ..< 200, at: 100))  // continues it in the buffer and the PTY stream: joins
        queue.push(try span(250 ..< 300, at: 200))  // continues the PTY stream, not the buffer: stays apart
        queue.push(.output(Data("decoded".utf8), colors: nil))  // a decoded chunk never joins a slice
        queue.push(try span(0 ..< 50, at: 300))
        queue.push(.resized(TerminalReplay(cols: 80, rows: 24, data: Data())))
        queue.push(try span(50 ..< 100, at: 350))  // a grid replacement in between: stays apart
        queue.finish()
        let events = await Self.drain(queue)

        #expect(events == [
            .output(bytes[0 ..< 200], colors: nil),
            .output(bytes[250 ..< 300], colors: nil),
            .output(Data("decoded".utf8), colors: nil),
            .output(bytes[0 ..< 50], colors: nil),
            .resized(TerminalReplay(cols: 80, rows: 24, data: Data())),
            .output(bytes[50 ..< 100], colors: nil),
        ])
        guard case .output(let joined, _) = events.first else { return }
        #expect(Self.address(joined) == Self.address(buffer.bytes))  // the joined slice starts in the buffer
    }

    // MARK: Offsets

    /// The gap test of p05-ipc-097: a lost OUTPUT asks once for a fresh READY, screen bytes until it are
    /// dropped, and output after it continues at the READY's cut, so the view ends with the host's screen.
    @Test func aGapAsksForASnapshotAndTheNextReadyRestoresTheScreen() async throws {
        var builder = FrameBuilder()
        builder.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")
        builder.add(.output, offset: 1000, payload: Self.text("live-bytes-at-1000-"))  // 19 bytes: next is 1019
        builder.add(.output, offset: 1030, payload: Self.text("bytes-after-a-lost-chunk"))  // gap
        builder.add(.output, offset: 1054, payload: Self.text("still-before-the-new-ready"))  // dropped
        builder.grid(offset: 1080, replay: "a-grid-of-the-old-screen", pending: "")  // dropped
        builder.ready(offset: 2000, generation: 2, data: "SNAPSHOT-READY-TWO")
        builder.add(.output, offset: 1990, payload: Self.text("0123456789abcdefghij"))  // 1990 ..< 2010
        builder.add(.output, offset: 2010, payload: Self.text("continues-at-2010-ok"))
        let hooks = Hooks()
        let events = await run(try builder.frames().frames, hooks: hooks)

        #expect(hooks.requests.withLock { $0 } == [.gap])
        #expect(events == [
            .snapshot(Self.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")),
            .output(Data(Self.text("live-bytes-at-1000-")), colors: nil),
            .snapshot(Self.ready(offset: 2000, generation: 2, data: "SNAPSHOT-READY-TWO")),
            // The READY holds the screen through 2000: only the bytes after its cut are new.
            .output(Data("abcdefghij".utf8), colors: nil),
            .output(Data(Self.text("continues-at-2010-ok")), colors: nil),
        ])
    }

    @Test func outputBeforeTheReadyCutAndItsSidecarAreDropped() async throws {
        var builder = FrameBuilder()
        builder.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")
        builder.add(.output, offset: 900, payload: Self.bytes(0x78, count: 50))
        builder.add(.event, offset: 900, payload: Self.text(#"{"event":"output","surface":3,"colors":{"fg":"#000000"}}"#))
        builder.add(.output, offset: 1000, payload: Self.bytes(0x79, count: 40))
        let events = await run(try builder.frames().frames)

        #expect(events == [
            .snapshot(Self.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")),
            .output(Data(Self.bytes(0x79, count: 40)), colors: nil),
        ])
    }

    /// A GRID cut before the READY arrives after it: the READY's screen already has the resize, so replaying
    /// the grid would put the mirror back at 900 and lose the bytes 900 ..< 1000.
    @Test func aGridBeforeTheReadyCutIsDropped() async throws {
        var builder = FrameBuilder()
        builder.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")
        builder.grid(offset: 900, replay: "a-grid-of-the-old-screen", pending: "")
        builder.add(.output, offset: 1000, payload: Self.bytes(0x79, count: 40))
        let hooks = Hooks()
        let events = await run(try builder.frames().frames, hooks: hooks)

        #expect(hooks.requests.withLock { $0 }.isEmpty)
        #expect(events == [
            .snapshot(Self.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")),
            .output(Data(Self.bytes(0x79, count: 40)), colors: nil),
        ])
    }

    @Test func aByteReplayStreamReattachesOnAGap() async throws {
        var builder = FrameBuilder()
        builder.replay(offset: 0, data: "replayed-screen-bytes")
        builder.add(.output, offset: 5, payload: Self.bytes(0x61, count: 32))
        let hooks = Hooks()
        let events = await run(try builder.frames().frames, hooks: hooks)

        #expect(hooks.requests.withLock { $0 }.isEmpty)  // no snapshot to ask for on a byte-replay attach
        #expect(events == [
            .replay(TerminalReplay(cols: 80, rows: 24, data: Data("replayed-screen-bytes".utf8))),
            .closed(.overflow),
        ])
    }

    @Test func aReadyLineSetsTheOffsetFramesContinueFrom() async throws {
        var decoder = TerminalAttachFrameDecoder(surface: Self.surface)
        let ready = Self.ready(offset: 500, generation: 1, data: "SNAPSHOT-READY-ONE")
        #expect(decoder.admit(line: DecodedAttachLine(event: .snapshot(ready))) == .snapshot(ready))
        var builder = FrameBuilder()
        builder.add(.output, offset: 400, payload: Self.bytes(0x61, count: 50))  // before the cut: dropped
        builder.add(.output, offset: 500, payload: Self.bytes(0x62, count: 50))
        let events = await run(try builder.frames().frames, decoder: &decoder)

        #expect(events == [.output(Data(Self.bytes(0x62, count: 50)), colors: nil)])
        #expect(decoder.nextOffset == 550)
    }

    // MARK: Frame kinds

    @Test func aGridReplacesTheMirrorWithItsReplayAndPendingSequence() async throws {
        var builder = FrameBuilder()
        builder.replay(offset: 0, data: "replayed-screen-bytes")
        builder.add(.output, offset: 0, payload: Self.bytes(0x61, count: 20))
        builder.grid(offset: 20, replay: "GRID-REPLAY-BYTES-0123", pending: "\u{1b}[3")
        builder.add(.output, offset: 20, payload: Self.bytes(0x62, count: 20))
        let events = await run(try builder.frames().frames)

        #expect(events == [
            .replay(TerminalReplay(cols: 80, rows: 24, data: Data("replayed-screen-bytes".utf8))),
            .output(Data(Self.bytes(0x61, count: 20)), colors: nil),
            .resized(TerminalReplay(cols: 100, rows: 30, data: Data("GRID-REPLAY-BYTES-0123".utf8),
                                    pending: Data("\u{1b}[3".utf8))),
            .output(Data(Self.bytes(0x62, count: 20)), colors: nil),
        ])
    }

    @Test func aSidecarGivesColorsAndTheEchoAfterItsChunk() async throws {
        var builder = FrameBuilder()
        builder.replay(offset: 0, data: "replayed-screen-bytes")
        builder.add(.output, offset: 0, payload: Self.bytes(0x61, count: 20))
        builder.add(.event, offset: 0, payload: Self.text(#"{"event":"output","surface":3,"flow":7}"#))
        builder.add(.output, offset: 20, payload: Self.bytes(0x62, count: 20))
        builder.add(.event, offset: 20, payload: Self.text(#"{"event":"output","surface":3,"colors":{"fg":"#ffffff"},"flow":8}"#))
        builder.add(.event, offset: 40, payload: Self.text(#"{"event":"detached","surface":3}"#))
        let events = await run(try builder.frames().frames)
        let colors = try JSONDecoder().decode(TerminalColors.self, from: Data(#"{"fg":"#ffffff"}"#.utf8))

        #expect(events == [
            .replay(TerminalReplay(cols: 80, rows: 24, data: Data("replayed-screen-bytes".utf8))),
            .output(Data(Self.bytes(0x61, count: 20)), colors: nil),
            .inputEcho(flow: 7),
            .output(Data(Self.bytes(0x62, count: 20)), colors: nil),
            .colorsChanged(colors),
            .inputEcho(flow: 8),
            .closed(.surfaceGone),
        ])
    }

    /// The writer cuts an output past BULK_FRAME_MAX (32 KiB) into OUTPUT frames, each with its own offset;
    /// the sidecar comes after the last one with the offset of the first.
    @Test func aChunkedOutputKeepsItsSidecar() async throws {
        let chunk = 32 * 1024
        var builder = FrameBuilder()
        builder.replay(offset: 1000, data: "replayed-screen-bytes")
        let first = Self.bytes(0x61, count: chunk)
        let second = Self.bytes(0x62, count: 40 * 1024 - chunk)
        builder.add(.output, offset: 1000, payload: first)
        builder.add(.output, offset: 1000 + UInt64(chunk), payload: second)
        builder.add(.event, offset: 1000,
                    payload: Self.text(#"{"event":"output","surface":3,"colors":{"fg":"#ffffff"},"flow":9}"#))
        let events = await run(try builder.frames().frames)
        let colors = try JSONDecoder().decode(TerminalColors.self, from: Data(#"{"fg":"#ffffff"}"#.utf8))

        #expect(events == [
            .replay(TerminalReplay(cols: 80, rows: 24, data: Data("replayed-screen-bytes".utf8))),
            // A frame header lies between the chunks in the buffer, so the queue keeps them apart.
            .output(Data(first), colors: nil),
            .output(Data(second), colors: nil),
            .colorsChanged(colors),
            .inputEcho(flow: 9),
        ])
    }

    /// The READY's cut falls in the second chunk: the first is on the screen already and dropped, the rest of
    /// the second is new, so the output reached the view and its sidecar applies.
    @Test func aChunkedOutputTrimmedByTheReadyKeepsItsSidecar() async throws {
        let chunk = 32 * 1024
        var builder = FrameBuilder()
        builder.ready(offset: 40000, generation: 1, data: "SNAPSHOT-READY-ONE")
        builder.add(.output, offset: 0, payload: Self.bytes(0x61, count: chunk))
        builder.add(.output, offset: UInt64(chunk), payload: Self.bytes(0x62, count: chunk))
        builder.add(.event, offset: 0, payload: Self.text(#"{"event":"output","surface":3,"flow":5}"#))
        let events = await run(try builder.frames().frames)

        #expect(events == [
            .snapshot(Self.ready(offset: 40000, generation: 1, data: "SNAPSHOT-READY-ONE")),
            .output(Data(Self.bytes(0x62, count: 2 * chunk - 40000)), colors: nil),
            .inputEcho(flow: 5),
        ])
    }

    @Test func aChunkedHistoryIsPutBackTogether() async throws {
        var builder = FrameBuilder()
        builder.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")
        let history = String(repeating: "history-page-", count: 40)
        let payload = Self.bulk(meta: #"{"event":"snapshot","surface":3,"phase":"history","generation":1,"offset":1000,"version":1,"data_len":\#(history.utf8.count)}"#,
                                raw: Self.text(history))
        // The meta itself is cut: the first chunk ends inside it.
        builder.add(.snapshot, offset: 1000, payload: Array(payload[0 ..< 10]))
        builder.add(.snapshotMore, offset: 1000, payload: Array(payload[10 ..< 200]))
        builder.add(.snapshotMore, offset: 1000, payload: Array(payload[200...]))
        let events = await run(try builder.frames().frames)

        #expect(events == [
            .snapshot(Self.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")),
            .snapshot(TerminalSnapshotFrame(phase: .history, generation: 1, offset: 1000, version: 1,
                                            data: Data(history.utf8))),
        ])
    }

    @Test func aFrameInsideAnUnfinishedSnapshotIsABrokenStream() async throws {
        var builder = FrameBuilder()
        builder.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE")
        let payload = Self.bulk(meta: #"{"event":"snapshot","surface":3,"phase":"history","generation":1,"offset":1000,"version":1,"data_len":100}"#,
                                raw: Self.bytes(0x68, count: 100))
        builder.add(.snapshot, offset: 1000, payload: Array(payload[0 ..< 60]))
        builder.add(.output, offset: 1000, payload: Self.bytes(0x61, count: 20))
        let hooks = Hooks()
        let events = await run(try builder.frames().frames, hooks: hooks)

        #expect(hooks.requests.withLock { $0 } == [.gap])
        #expect(events == [.snapshot(Self.ready(offset: 1000, generation: 1, data: "SNAPSHOT-READY-ONE"))])
    }

    // MARK: Helpers

    /// Delivers every frame to a fresh queue and returns what the view reads.
    private func run(_ frames: [TerminalAttachFrame], hooks: Hooks = Hooks()) async -> [TerminalChannelEvent] {
        var decoder = TerminalAttachFrameDecoder(surface: Self.surface)
        return await run(frames, decoder: &decoder, hooks: hooks)
    }

    private func run(_ frames: [TerminalAttachFrame], decoder: inout TerminalAttachFrameDecoder,
                     hooks: Hooks = Hooks()) async -> [TerminalChannelEvent] {
        let queue = TerminalEventQueue(recorder: nil)
        for frame in frames {
            TerminalAttachFrameDecoder.deliver(decoder.admit(frame, decoder: wire), to: queue, delivery: hooks.delivery)
        }
        queue.finish()
        return await Self.drain(queue)
    }

    private static func drain(_ queue: TerminalEventQueue) async -> [TerminalChannelEvent] {
        var events: [TerminalChannelEvent] = []
        while let event = await queue.next() { events.append(event) }
        return events
    }

    private static func ready(offset: UInt64, generation: UInt64, data: String) -> TerminalSnapshotFrame {
        TerminalSnapshotFrame(phase: .ready, generation: generation, offset: offset, version: 1, cols: 80, rows: 24,
                              data: Data(data.utf8))
    }

    private static func text(_ string: String) -> [UInt8] { Array(string.utf8) }

    private static func bytes(_ value: UInt8, count: Int) -> [UInt8] { [UInt8](repeating: value, count: count) }

    /// `meta_len u32 LE | meta | raw`.
    fileprivate static func bulk(meta: String, raw: [UInt8]) -> [UInt8] {
        let meta = Array(meta.utf8)
        return littleEndian(UInt64(meta.count), bytes: 4) + meta + raw
    }

    fileprivate static func littleEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0 ..< bytes).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    private static func address(_ data: Data) -> UInt {
        // SAFETY: only the address is read, inside the closure that lends it.
        unsafe data.withUnsafeBytes { buffer in unsafe UInt(bitPattern: buffer.baseAddress) }
    }
}

/// What the decoder asked the attachment for.
private final class Hooks: Sendable {
    let requests = Mutex<[SnapshotRequestReason]>([])

    var delivery: TerminalAttachFrameDecoder.Delivery {
        TerminalAttachFrameDecoder.Delivery(
            sizeState: { _, _ in },
            requestSnapshot: { reason in self.requests.withLock { $0.append(reason) } },
            outputDecoded: { _ in })
    }
}

/// Frames back to back in one read buffer, header and payload, as the connection's reader receives them.
private struct FrameBuilder {
    private var wire: [UInt8] = []
    private var cuts: [(kind: TerminalAttachFrame.Kind, offset: UInt64, range: Range<Int>)] = []

    mutating func add(_ kind: TerminalAttachFrame.Kind, offset: UInt64, payload: [UInt8]) {
        wire += [0xFF, kind.rawValue, 1, 0] + TerminalAttachmentFrameTests.littleEndian(UInt64(payload.count), bytes: 4)
            + TerminalAttachmentFrameTests.littleEndian(offset, bytes: 8)
        let start = wire.count
        wire += payload
        cuts.append((kind, offset, start ..< wire.count))
    }

    mutating func replay(offset: UInt64, data: String) {
        let meta = #"{"event":"vt-state","surface":3,"cols":80,"rows":24,"data_len":\#(data.utf8.count),"kitty_image_aliases":[],"colors":null}"#
        add(.replay, offset: offset, payload: TerminalAttachmentFrameTests.bulk(meta: meta, raw: Array(data.utf8)))
    }

    mutating func ready(offset: UInt64, generation: UInt64, data: String) {
        let meta = #"{"event":"snapshot","surface":3,"phase":"ready","generation":\#(generation),"offset":\#(offset),"version":1,"cols":80,"rows":24,"data_len":\#(data.utf8.count)}"#
        add(.snapshot, offset: offset, payload: TerminalAttachmentFrameTests.bulk(meta: meta, raw: Array(data.utf8)))
    }

    mutating func grid(offset: UInt64, replay: String, pending: String) {
        let pendingField = pending.isEmpty ? "" : #","pending_len":\#(pending.utf8.count)"#
        let meta = #"{"event":"resized","surface":3,"cols":100,"rows":30\#(pendingField)}"#
        add(.grid, offset: offset,
            payload: TerminalAttachmentFrameTests.bulk(meta: meta, raw: Array(replay.utf8) + Array(pending.utf8)))
    }

    func frames() throws -> (buffer: TerminalReadBuffer, frames: [TerminalAttachFrame]) {
        let buffer = TerminalReadBuffer(Data(wire))
        let frames = try cuts.map { cut in
            TerminalAttachFrame(kind: cut.kind, offset: cut.offset,
                                payload: try #require(TerminalFrameBytes(buffer: buffer, range: cut.range)))
        }
        return (buffer, frames)
    }
}
