import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxLocalLinux

@Suite("Local Linux terminal lane")
struct LocalLinuxTerminalLaneTests {
    @Test("replay is first and live chunks continue at the absolute cursor")
    func replayPrecedesLiveOutputAndSequencesRemainContiguous() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 64)
        _ = await ring.append(Data("history".utf8))
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)

        let replay = try #require(try await lane.receiveOutput())
        #expect(replay.kind == .replay)
        #expect(replay.retainedBaseSequence == 0)
        #expect(replay.sequence == 0)
        #expect(replay.currentSequence == 7)
        #expect(replay.bytes == Data("history".utf8))

        await source.emit(Data(" one".utf8))
        let firstChunk = try #require(try await lane.receiveOutput())
        #expect(firstChunk.kind == .chunk)
        #expect(firstChunk.retainedBaseSequence == 0)
        #expect(firstChunk.sequence == 7)
        #expect(firstChunk.currentSequence == 11)
        #expect(firstChunk.bytes == Data(" one".utf8))

        await source.emit(Data("\n".utf8))
        let secondChunk = try #require(try await lane.receiveOutput())
        #expect(secondChunk.kind == .chunk)
        #expect(secondChunk.sequence == 11)
        #expect(secondChunk.currentSequence == 12)
        #expect(secondChunk.bytes == Data("\n".utf8))
        #expect(await ring.currentSequence == 12)
    }

    @Test("a cursor replays only the requested retained suffix")
    func cursorSelectsReplaySuffixAndReportsRetainedFloor() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 4)
        _ = await ring.append(Data("abcdef".utf8))
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: 4)

        let replay = try #require(try await lane.receiveOutput())
        #expect(replay.kind == .replay)
        #expect(replay.retainedBaseSequence == 2)
        #expect(replay.sequence == 4)
        #expect(replay.currentSequence == 6)
        #expect(replay.bytes == Data("ef".utf8))
    }

    @Test("a stale cursor fails closed instead of replaying an incomplete history")
    func staleCursorIsRejected() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 2)
        _ = await ring.append(Data("abc".utf8))
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: 0)

        await #expect(throws: LocalLinuxLaneError.cursorGap(
            requested: 0,
            retainedBase: 1,
            current: 3
        )) {
            try await lane.receiveOutput()
        }
        await source.finishOutput()
    }

    @Test("a cursor beyond the current sequence is rejected")
    func futureCursorIsRejected() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 8)
        _ = await ring.append(Data("abc".utf8))
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: 4)

        await #expect(throws: LocalLinuxLaneError.cursorAhead(
            requested: 4,
            current: 3
        )) {
            try await lane.receiveOutput()
        }
        await source.finishOutput()
    }

    @Test("large source writes are split without breaking sequence continuity")
    func largeWritesAreBoundedAndStamped() async throws {
        let ring = LocalLinuxScrollbackRing(limit: LocalLinuxTerminalLane.maximumOutputByteCount * 2)
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        _ = try #require(try await lane.receiveOutput())

        let payload = Data(repeating: 0x61, count: LocalLinuxTerminalLane.maximumOutputByteCount + 17)
        await source.emit(payload)

        let first = try #require(try await lane.receiveOutput())
        let second = try #require(try await lane.receiveOutput())
        #expect(first.bytes.count == LocalLinuxTerminalLane.maximumOutputByteCount)
        #expect(second.bytes.count == 17)
        #expect(first.sequence == 0)
        #expect(first.currentSequence == UInt64(LocalLinuxTerminalLane.maximumOutputByteCount))
        #expect(second.sequence == first.currentSequence)
        #expect(second.currentSequence == UInt64(payload.count))
        #expect(first.bytes + second.bytes == payload)
    }

    @Test("an evicted live write still carries a valid sequence envelope")
    func liveWriteLargerThanRingKeepsEnvelopeValid() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 2)
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        _ = try #require(try await lane.receiveOutput())

        let payload = Data("abcd".utf8)
        await source.emit(payload)

        let frame = try #require(try await lane.receiveOutput())
        #expect(frame.kind == .chunk)
        #expect(frame.bytes == payload)
        #expect(frame.sequence == 0)
        #expect(frame.currentSequence == UInt64(payload.count))
        // The coordinator rejects a frame whose advertised retained floor is
        // newer than the frame start, even when the ring evicts old bytes.
        #expect(frame.retainedBaseSequence <= frame.sequence)

        let snapshot = try await ring.validatedSnapshot(from: nil)
        #expect(snapshot.retainedBaseSequence == 2)
        #expect(snapshot.currentSequence == 4)
        #expect(snapshot.bytes == Data("cd".utf8))
        await lane.close()
    }

    @Test("input is forwarded to the sink as exact UTF-8 bytes")
    func inputUsesUTF8AndReachesSink() async throws {
        let source = TestLocalLinuxOutputSource()
        let sink = TestInputSink()
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil,
            input: { sink.record($0) }
        )

        try await lane.sendInput("é\n")
        try await lane.sendInput("")

        #expect(sink.inputs == [Data("é\n".utf8)])
    }

    @Test("closing a lane finishes a blocked receive without hanging up the shell")
    func closeUnblocksReceiveAndKeepsSourceAlive() async throws {
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil
        )
        _ = try #require(try await lane.receiveOutput())

        let pending = Task { () -> MobileTerminalLaneOutputFrame? in
            do {
                return try await lane.receiveOutput()
            } catch {
                return nil
            }
        }
        await Task.yield()
        await lane.close()

        #expect(await pending.value == nil)
        #expect(await source.outputFinished() == false)
        await #expect(throws: LocalLinuxLaneError.closed) {
            try await lane.sendInput("x")
        }
    }

    @Test("a second receive is rejected while the first one waits")
    func concurrentReceivesAreRejected() async throws {
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil
        )
        _ = try #require(try await lane.receiveOutput())

        let first = Task { () -> LaneReceiveOutcome in
            do {
                return .frame(try await lane.receiveOutput())
            } catch let error as LocalLinuxLaneError {
                return .error(error)
            } catch {
                return .unexpected
            }
        }
        let second = Task { () -> LaneReceiveOutcome in
            do {
                return .frame(try await lane.receiveOutput())
            } catch let error as LocalLinuxLaneError {
                return .error(error)
            } catch {
                return .unexpected
            }
        }
        await Task.yield()
        await source.emit(Data("ready".utf8))

        let outcomes = [await first.value, await second.value]
        let concurrentErrors = outcomes.reduce(into: 0) { count, outcome in
            if case .error(.concurrentReceive) = outcome {
                count += 1
            }
        }
        let deliveredFrames = outcomes.reduce(into: 0) { count, outcome in
            if case .frame(.some(let frame)) = outcome, frame.bytes == Data("ready".utf8) {
                count += 1
            }
        }
        #expect(concurrentErrors == 1)
        #expect(deliveredFrames == 1)
        await lane.close()
    }

    @Test("a finished source ends the ring and every attached lane")
    func sourceEndFinishesRingAndLanes() async throws {
        let source = TestLocalLinuxOutputSource()
        let ring = LocalLinuxScrollbackRing()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        _ = try #require(try await lane.receiveOutput())

        await source.finishOutput()

        var ended = ring.sourceEnded.makeAsyncIterator()
        #expect(await ended.next() == nil)
        #expect(try await lane.receiveOutput() == nil)
        await lane.close()
    }

    @Test("one ring fans out each live frame to multiple lanes")
    func ringFansOutLiveOutput() async throws {
        let ring = LocalLinuxScrollbackRing()
        let source = TestLocalLinuxOutputSource()
        let first = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        let second = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)

        _ = try #require(try await first.receiveOutput())
        _ = try #require(try await second.receiveOutput())
        await source.emit(Data("shared".utf8))

        let firstFrame = try #require(try await first.receiveOutput())
        let secondFrame = try #require(try await second.receiveOutput())
        #expect(firstFrame == secondFrame)
        #expect(firstFrame.sequence == 0)
        #expect(firstFrame.currentSequence == 6)
        await first.close()
        await second.close()
    }

    @Test("starting a ring before subscription retains a bounded replay suffix")
    func startDrainsDetachedOutputIntoBoundedHistory() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 4)
        let source = TestLocalLinuxOutputSource()

        // Start the pump before creating a lane. This is the production order
        // used while a local computer is detached from the terminal view.
        try await ring.start(source: source)
        await source.emit(Data("abcdef".utf8))

        // `emit` only enqueues into the source stream. Wait for the ring's
        // actor to observe the full write without using a timing delay.
        #expect(await Self.waitForSequence(ring, expected: 6))

        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        let replay = try #require(try await lane.receiveOutput())
        #expect(replay.kind == .replay)
        #expect(replay.retainedBaseSequence == 2)
        #expect(replay.sequence == 2)
        #expect(replay.currentSequence == 6)
        #expect(replay.bytes == Data("cdef".utf8))

        await lane.close()
    }

    @Test("a slow subscriber reattaches from replay after its queue overflows")
    func slowSubscriberRecoversWithReplay() async throws {
        let ring = LocalLinuxScrollbackRing(limit: 256)
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        _ = try #require(try await lane.receiveOutput())

        // The lane's bounded subscriber queue holds 64 frames. Emit one more
        // frame before reading so the ring must detach that subscriber rather
        // than silently discard output.
        for offset in 0..<65 {
            await source.emit(Data([UInt8(0x61 + offset)]))
        }
        #expect(await Self.waitForSequence(ring, expected: 65))

        for _ in 0..<64 {
            let frame = try #require(try await lane.receiveOutput())
            #expect(frame.kind == .chunk)
        }

        // The next receive observes the overflow marker, creates a fresh
        // bounded subscription, and returns a replay frame. The coordinator
        // can therefore reset Ghostty and continue without losing the shell.
        let replay = try #require(try await lane.receiveOutput())
        #expect(replay.kind == .replay)
        #expect(replay.bytes.count == 65)
        #expect(replay.currentSequence == 65)

        await lane.close()
    }

    @Test("a shared ring rejects attaching a different source")
    func ringRejectsSourceReplacement() async throws {
        let ring = LocalLinuxScrollbackRing()
        let firstSource = TestLocalLinuxOutputSource()
        let secondSource = TestLocalLinuxOutputSource()
        let first = LocalLinuxTerminalLane(source: firstSource, ring: ring, cursor: nil)
        let second = LocalLinuxTerminalLane(source: secondSource, ring: ring, cursor: nil)

        _ = try #require(try await first.receiveOutput())
        await #expect(throws: LocalLinuxLaneError.sourceMismatch) {
            try await second.receiveOutput()
        }
        await first.close()
        await second.close()
    }

    @Test("a finished ring keeps its source identity")
    func ringRejectsSourceReplacementAfterEOF() async throws {
        let ring = LocalLinuxScrollbackRing()
        let originalSource = TestLocalLinuxOutputSource()
        let originalLane = LocalLinuxTerminalLane(
            source: originalSource,
            ring: ring,
            cursor: nil
        )

        _ = try #require(try await originalLane.receiveOutput())
        await originalSource.finishOutput()
        #expect(try await originalLane.receiveOutput() == nil)

        let replacementSource = TestLocalLinuxOutputSource()
        let replacementLane = LocalLinuxTerminalLane(
            source: replacementSource,
            ring: ring,
            cursor: nil
        )
        await #expect(throws: LocalLinuxLaneError.sourceMismatch) {
            try await replacementLane.receiveOutput()
        }
        await originalLane.close()
        await replacementLane.close()
    }

    @Test("a same-source lane attached after EOF receives a finished live stream")
    func sameSourceReattachAfterEOFDoesNotHang() async throws {
        let ring = LocalLinuxScrollbackRing()
        let source = TestLocalLinuxOutputSource()
        let firstLane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)

        _ = try #require(try await firstLane.receiveOutput())
        await source.emit(Data("done".utf8))
        _ = try #require(try await firstLane.receiveOutput())
        await source.finishOutput()
        #expect(try await firstLane.receiveOutput() == nil)

        let secondLane = LocalLinuxTerminalLane(source: source, ring: ring, cursor: nil)
        let replay = try #require(try await secondLane.receiveOutput())
        #expect(replay.kind == .replay)
        #expect(replay.bytes == Data("done".utf8))

        let pending = Task { () -> MobileTerminalLaneOutputFrame? in
            try? await secondLane.receiveOutput()
        }
        #expect(await pending.value == nil)
        await firstLane.close()
        await secondLane.close()
    }

    private static func waitForSequence(
        _ ring: LocalLinuxScrollbackRing,
        expected: UInt64,
        attempts: Int = 1_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if await ring.currentSequence >= expected {
                return true
            }
            await Task.yield()
        }
        return await ring.currentSequence >= expected
    }
}

private enum LaneReceiveOutcome: Sendable {
    case frame(MobileTerminalLaneOutputFrame?)
    case error(LocalLinuxLaneError)
    case unexpected
}

private actor TestLocalLinuxOutputSource: LocalLinuxOutputSource {
    nonisolated let output: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private var didFinishOutput = false

    init() {
        var streamContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) {
            streamContinuation = $0
        }
        self.output = stream
        self.continuation = streamContinuation
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func finishOutput() {
        continuation.finish()
        didFinishOutput = true
    }

    func outputFinished() -> Bool {
        didFinishOutput
    }
}

private final class TestInputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []

    func record(_ data: Data) {
        lock.withLock { recorded.append(data) }
    }

    var inputs: [Data] {
        lock.withLock { recorded }
    }
}
