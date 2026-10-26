import AppKit
import Atomics
@testable import CmuxNextInput
import CmuxNextInputCore
import CmuxNextSignposts
import Darwin
import Testing

/// InputLatencyTracker (p04-input-004): stage order through a fake commit boundary and presentation clock, one
/// boundary per turn, missed commits, refused late marks, the half-ring batch, and no allocation per event.
@MainActor
struct InputLatencyTrackerTests {
    /// The parts of a tracker a test drives: its clock, the boundary it asked for, the slots it emitted.
    @MainActor
    final class Harness {
        let clock = ManagedAtomic<UInt64>(1_000_000_000)
        let presentation = FakePresentation()
        /// The boundary the tracker asked for this turn (one optional, not an array: an array would box the closure).
        var boundary: (@MainActor (CommitBoundary.Outcome) -> Void)?
        /// Boundaries asked for since the last ``commit(_:)``.
        var boundaryRequests = 0
        var emitted: [InputLatencySlot] = []
        var batches: [[InputLatencySlot]] = []
        private(set) var tracker: InputLatencyTracker!

        init(ringCapacity: Int = 256, batches wantsBatches: Bool = false, records: Bool = true,
             frameIntervals: (any InputFrameIntervals)? = nil) {
            let clock = clock
            tracker = InputLatencyTracker(
                table: InputLatencySlotTable(), ring: InputLatencyRing(capacity: ringCapacity), presentation: presentation,
                afterCommit: { [weak self] in
                    guard let self else { return }
                    self.boundaryRequests += 1
                    self.boundary = $0
                },
                emit: { [weak self] slot in if records { self?.emitted.append(slot) } },
                batchSink: wantsBatches ? { [weak self] batch in self?.batches.append(batch) } as InputLatencyTracker.BatchSink : nil,
                frameIntervals: frameIntervals, now: { clock.load(ordering: .relaxed) })
        }

        /// Moves the clock `nanos` ahead and returns the new time.
        @discardableResult
        func advance(_ nanos: UInt64) -> UInt64 {
            clock.wrappingIncrementThenLoad(by: nanos, ordering: .relaxed)
        }

        /// Runs the boundary the tracker asked for this turn, as the run loop does after Core Animation's commit.
        func commit(_ outcome: CommitBoundary.Outcome = .committed) {
            let asked = boundary
            boundary = nil
            boundaryRequests = 0
            asked?(outcome)
        }
    }

    /// A presentation clock that answers commit end + 1 ms and counts link holds.
    final class FakePresentation: InputPresentationEstimating {
        static let renderServerNanos: UInt64 = 1_000_000
        var holds = 0
        var asked: [UInt64] = []
        var recordsAsks = true

        func holdLinkForInput(in window: NSWindow?) { holds += 1 }

        func presentedNanos(commitEndNanos: UInt64, in window: NSWindow?) -> UInt64 {
            if recordsAsks { asked.append(commitEndNanos) }
            return commitEndNanos + Self.renderServerNanos
        }
    }

    private func begin(_ harness: Harness, kind: InputEventKind = .keyPress, target: InputTarget = .terminal,
                       ageNanos: UInt64 = 2_000_000) -> InputLatencyToken? {
        let now = harness.clock.load(ordering: .relaxed)
        return harness.tracker.begin(kind: kind, target: target, entrypoint: .person,
                                     eventTimestamp: TimeInterval(now - ageNanos) / 1e9, window: nil)
    }

    @Test("A key's stages close in order at the turn's commit, presented from the commit")
    func stagesCloseInOrder() throws {
        let harness = Harness()
        let token = try #require(begin(harness))
        #expect(harness.presentation.holds == 1)
        harness.advance(100_000)
        #expect(harness.tracker.mark(token, .textInputStart))
        harness.advance(300_000)
        #expect(harness.tracker.mark(token, .textInputEnd))
        harness.advance(200_000)
        harness.tracker.endDispatch(token)
        harness.advance(2_000_000)
        #expect(harness.emitted.isEmpty, "the slot waits for the commit")
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(harness.emitted.count == 1)
        #expect(slot.kind == .keyPress && slot.target == .terminal && slot.entrypoint == .person)
        #expect(slot.presentationSource == .estimatedVsync)
        let order: [InputStage] = [.generated, .arrivedMain, .dispatchStart, .textInputStart, .textInputEnd,
                                   .dispatchEnd, .mainCommit, .presented]
        for stage in order { #expect(slot.reached(stage), "\(stage)") }
        for (earlier, later) in zip(order, order.dropFirst()) {
            #expect(slot[earlier] <= slot[later], "\(earlier) before \(later)")
        }
        #expect(slot.nanos(from: .generated, to: .arrivedMain) == 2_000_000)
        #expect(slot.nanos(from: .mainCommit, to: .presented) == FakePresentation.renderServerNanos)
        #expect(harness.presentation.asked == [slot.mainCommit])
        for skipped: InputStage in [.lastGenerated, .contentSubmitted, .daemonReceived, .ptyWritten, .echoRead,
                                    .echoSent] {
            #expect(!slot.reached(skipped), "\(skipped)")
        }
        #expect(harness.tracker.closedCount == 1)
    }

    @Test("Every slot opened in one turn closes at that turn's one boundary")
    func oneBoundaryPerTurn() throws {
        let harness = Harness()
        let first = try #require(begin(harness))
        let second = try #require(begin(harness, kind: .mousePress, target: .sidebar))
        let third = try #require(begin(harness, kind: .scrollFirstUpdate, target: .layout))
        #expect(harness.boundaryRequests == 1)
        for token in [first, second, third] { harness.tracker.endDispatch(token) }
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress, .scrollFirstUpdate])
        #expect(harness.tracker.pendingCount == 0)

        _ = try #require(begin(harness))
        #expect(harness.boundaryRequests == 1, "the next turn asks for its own boundary")
    }

    /// Holds a tracker whose emit callback opens another slot on that same tracker.
    @MainActor
    final class Reopener {
        var tracker: InputLatencyTracker?
        var reopened: InputLatencyToken?
    }

    @Test("A slot opened while the turn's slots close waits for the next boundary")
    func slotOpenedDuringCloseWaitsForTheNextBoundary() throws {
        let harness = Harness()
        let box = Reopener()
        let tracker = InputLatencyTracker(
            table: InputLatencySlotTable(), ring: InputLatencyRing(), presentation: harness.presentation,
            afterCommit: { boundary in
                harness.boundaryRequests += 1
                harness.boundary = boundary
            },
            emit: { slot in
                harness.emitted.append(slot)
                guard box.reopened == nil else { return }
                box.reopened = box.tracker?.begin(kind: .mousePress, target: .layout, entrypoint: .person,
                                                  eventTimestamp: 0, window: nil)
            },
            batchSink: nil, now: { 2_000_000_000 })
        box.tracker = tracker
        _ = try #require(tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person, eventTimestamp: 0,
                                       window: nil))
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress])
        #expect(box.reopened != nil)
        #expect(tracker.pendingCount == 1, "the reopened slot waits")
        #expect(harness.boundaryRequests == 1, "and asked for the next boundary")
        harness.commit()
        #expect(harness.emitted.map(\.kind) == [.keyPress, .mousePress])
        #expect(tracker.pendingCount == 0)
    }

    @Test("A missed commit closes the slot with its commit and presented stages skipped")
    func missedCommitSkipsPresented() throws {
        let harness = Harness()
        let token = try #require(begin(harness))
        harness.tracker.endDispatch(token)
        harness.commit(.missed)
        let slot = try #require(harness.emitted.first)
        #expect(slot.reached(.dispatchEnd))
        #expect(!slot.reached(.mainCommit) && !slot.reached(.presented))
        #expect(slot.totalNanos == nil)
        #expect(harness.presentation.asked.isEmpty)
    }

    @Test("A mark after the slot closed misses it, and a stage is written once")
    func lateAndRepeatedMarksAreRefused() throws {
        let harness = Harness()
        let token = try #require(begin(harness))
        #expect(harness.tracker.mark(token, .contentSubmitted))
        #expect(!harness.tracker.mark(token, .contentSubmitted), "written once")
        #expect(harness.tracker.markCausedFrameUpdate(token))
        harness.commit()
        harness.tracker.mark(token, .echoRead)
        let slot = try #require(harness.emitted.first)
        #expect(slot.causedFrameUpdate)
        #expect(!slot.reached(.echoRead))
    }

    @Test("Stages stamped from other threads land in the slot")
    func marksFromOtherThreads() async throws {
        let harness = Harness()
        let token = try #require(begin(harness))
        let tracker = harness.tracker!
        let stamp = harness.clock.load(ordering: .relaxed) + 500_000
        await withTaskGroup(of: Void.self) { group in
            for stage: InputStage in [.daemonReceived, .ptyWritten, .echoRead] {
                group.addTask { @Sendable in _ = tracker.mark(token, stage, at: stamp) }
            }
        }
        harness.commit()
        let slot = try #require(harness.emitted.first)
        #expect(slot.daemonReceived == stamp && slot.ptyWritten == stamp && slot.echoRead == stamp)
    }

    @Test("Each half ring of closed slots goes to the batch sink, oldest first")
    func halfRingGoesToTheSink() throws {
        let harness = Harness(ringCapacity: 8, batches: true)
        for turn in 0..<3 {
            for _ in 0..<3 { _ = try #require(begin(harness, target: turn == 0 ? .terminal : .textView)) }
            harness.commit()
        }
        #expect(harness.batches.map(\.count) == [4, 4])
        #expect(harness.batches.first?.first?.target == .terminal)
        #expect(harness.tracker.recent(1).first?.target == .textView)
    }

    @Test("An event timestamp of 0 or later than now opens the slot at now")
    func generatedNeverAfterArrival() {
        #expect(InputLatencyTracker.generatedNanos(eventTimestamp: 0, arrived: 5_000) == 5_000)
        #expect(InputLatencyTracker.generatedNanos(eventTimestamp: 10, arrived: 5_000) == 5_000)
        #expect(InputLatencyTracker.generatedNanos(eventTimestamp: 1, arrived: 3_000_000_000) == 1_000_000_000)
    }

    @Test("The input.latency message carries microsecond offsets, -1 for a skipped stage")
    func signpostMessageFields() {
        var slot = InputLatencySlot(kind: .scrollFirstUpdate, target: .chromiumPage, entrypoint: .automation,
                                    presentationSource: .hostFeedback, causedFrameUpdate: true, coalescedCount: 3)
        slot.generated = 10_000_000
        slot.dispatchStart = 10_250_000
        slot.presented = 18_000_000
        let message = InputLatencySignpostMessage(slot: slot)
        #expect(message.kind == InputEventKind.scrollFirstUpdate.rawValue)
        #expect(message.target == InputTarget.chromiumPage.rawValue)
        #expect(message.entrypoint == InputEntrypoint.automation.rawValue)
        #expect(message.presentationSource == InputPresentationSource.hostFeedback.rawValue)
        #expect(message.coalescedCount == 3 && message.causedFrameUpdate)
        #expect(message.generatedNanos == 10_000_000)
        #expect(message.dispatchStartMicros == 250)
        #expect(message.presentedMicros == 8_000)
        #expect(message.arrivedMainMicros == -1 && message.echoSentMicros == -1)
        #expect(message.traceArg1 == 8_000)
        #expect(message.traceArg0 >> 32 == 1)
        InputLatencyTracker.signpost(slot, to: Signposter(category: .input))
    }

    /// The per-event path (begin, a mark, the dispatch end, and the close at the commit) adds no allocation to the
    /// loop that runs it: compared with the same loop doing nothing, because a Debug loop allocates by itself.
    @Test("Tracking an event allocates nothing")
    func perEventPathAllocatesNothing() throws {
        let harness = Harness(records: false)
        harness.presentation.recordsAsks = false
        // Warm up: the boundary closure is built on the first begin.
        _ = begin(harness)
        harness.commit()
        let tracker = harness.tracker!
        let timestamp = TimeInterval(harness.clock.load(ordering: .relaxed)) / 1e9
        var opened = 0

        let control = MallocProbe.allocations { opened += ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")

        func run(_ body: () -> Void) -> Int? {
            MallocProbe.allocations {
                for _ in 0..<100 {
                    body()
                    harness.commit()
                }
            }
        }
        let baseline = try #require(run {
            for _ in 0..<64 { opened += 1 }
        })
        let tracked = run {
            for _ in 0..<64 {
                guard let token = tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                eventTimestamp: timestamp, window: nil) else { continue }
                tracker.mark(token, .textInputStart)
                tracker.endDispatch(token)
                opened += 1
            }
        }
        #expect(tracked == baseline, "the loop alone made \(baseline)")
        #expect(opened > 64 * 100)
    }
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (the one malloc stack logging
/// uses), as CmuxNextFeaturesTests' probe does.
private nonisolated struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = ManagedAtomic<Int>(0)
    static let thread = ManagedAtomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { MallocProbe.count.wrappingIncrement(ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
