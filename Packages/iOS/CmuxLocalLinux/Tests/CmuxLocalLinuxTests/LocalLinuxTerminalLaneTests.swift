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
        await source.hangup()
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
        await source.hangup()
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

        let snapshot = await ring.snapshot(from: nil)
        #expect(snapshot.retainedBaseSequence == 2)
        #expect(snapshot.currentSequence == 4)
        #expect(snapshot.bytes == Data("cd".utf8))
        await lane.close()
    }

    @Test("input is forwarded as exact UTF-8 bytes")
    func inputUsesUTF8AndFullWriteContract() async throws {
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil
        )

        try await lane.sendInput("é\n")

        #expect(await source.inputs() == [Data("é\n".utf8)])
    }

    @Test("empty and oversized input are rejected before touching the source")
    func inputBoundsFailBeforeWrite() async throws {
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil
        )

        await #expect(throws: LocalLinuxLaneError.emptyInput) {
            try await lane.sendInput("")
        }
        await #expect(throws: LocalLinuxLaneError.inputTooLarge) {
            try await lane.sendInput(
                String(repeating: "x", count: LocalLinuxTerminalLane.maximumInputByteCount + 1)
            )
        }
        #expect(await source.inputs().isEmpty)
    }

    @Test("a short source write is surfaced instead of silently dropping bytes")
    func partialInputWriteFailsLoudly() async throws {
        let source = TestLocalLinuxOutputSource(acceptedByteCount: 1)
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil
        )

        await #expect(throws: LocalLinuxLaneError.inputPartiallyAccepted(
            accepted: 1,
            expected: 3
        )) {
            try await lane.sendInput("abc")
        }
        #expect(await source.inputs() == [Data("abc".utf8)])
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
        #expect(await source.didHangUp() == false)
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

    @Test("terminate hangs up the source after detaching the lane")
    func terminateFinishesSource() async throws {
        let source = TestLocalLinuxOutputSource()
        let lane = LocalLinuxTerminalLane(
            source: source,
            ring: LocalLinuxScrollbackRing(),
            cursor: nil
        )
        _ = try #require(try await lane.receiveOutput())

        await lane.terminate()

        #expect(await source.didHangUp())
        #expect(await source.outputFinished())
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
        await source.hangup()
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
        await first.terminate()
        await second.terminate()
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
    private let acceptedByteCount: Int?
    private var sentInputs: [Data] = []
    private var didFinishOutput = false
    private var didHangUpValue = false

    init(acceptedByteCount: Int? = nil) {
        var streamContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) {
            streamContinuation = $0
        }
        self.output = stream
        self.continuation = streamContinuation
        self.acceptedByteCount = acceptedByteCount
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    func finishOutput() {
        continuation.finish()
        didFinishOutput = true
    }

    func send(_ data: Data) async throws -> Int {
        sentInputs.append(data)
        return acceptedByteCount ?? data.count
    }

    func hangup() async {
        didHangUpValue = true
        finishOutput()
    }

    func inputs() -> [Data] {
        sentInputs
    }

    func didHangUp() -> Bool {
        didHangUpValue
    }

    func outputFinished() -> Bool {
        didFinishOutput
    }
}
