import CmuxNextCompat
@testable import CmuxNextInputCore
import Foundation
import Testing

/// The input latency core: the slot is a plain value, the open-slot table takes
/// each stage once from any thread and refuses stale tokens, a full table drops and counts, and
/// the closed-slot ring hands over halves, wraps and counts what it overwrote. Run under TSan:
/// `swift test --sanitize=thread --filter InputLatencyRingTests`.
struct InputLatencyRingTests {
    private static let ms: UInt64 = 1_000_000

    /// What a test stamps for `stage` of an input generated at `generated`.
    private static func expected(_ generated: UInt64, _ stage: InputStage) -> UInt64 {
        generated + UInt64(stage.rawValue) * 10 + 1
    }

    // MARK: slot

    @Test func theSlotIsAPlainValue() {
        #expect(_isPOD(InputLatencySlot.self), "a slot must copy as bytes: no references in it")
    }

    @Test func aSlotReadsEachStageAndSkippedStagesAreZero() {
        var slot = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person)
        for stage in InputStage.allCases { #expect(slot[stage] == 0) }
        slot[.generated] = 10 * Self.ms
        slot[.presented] = 18 * Self.ms
        #expect(slot.totalNanos == 8 * Self.ms)
        #expect(slot.nanos(from: .generated, to: .dispatchEnd) == nil, "a skipped end has no duration")
        slot[.dispatchEnd] = 9 * Self.ms
        #expect(slot.nanos(from: .generated, to: .dispatchEnd) == 0, "a clock that ran backwards gives 0")
        #expect(slot.reached(.presented))
        #expect(!slot.reached(.echoRead))
    }

    // MARK: table

    @Test func aStageIsWrittenOnceAndSkippedStagesStayZero() throws {
        let table = InputLatencySlotTable()
        let generated = 100 * Self.ms
        let token = try #require(table.begin(kind: .keyPress, target: .terminal, entrypoint: .person, generated: generated))
        #expect(token.rawValue != 0)
        #expect(table.mark(token, .dispatchStart, at: generated + 2 * Self.ms))
        #expect(!table.mark(token, .dispatchStart, at: generated + 5 * Self.ms), "a second mark of a stage must not win")
        #expect(!table.mark(token, .dispatchEnd, at: 0), "0 means skipped and is never a mark")
        #expect(table.mark(token, .presented, at: generated + 9 * Self.ms))
        let slot = try #require(table.close(token))
        #expect(slot.kind == .keyPress)
        #expect(slot.target == .terminal)
        #expect(slot.entrypoint == .person)
        #expect(slot.coalescedCount == 1)
        #expect(slot.presentationSource == .estimatedVsync)
        #expect(!slot.causedFrameUpdate)
        #expect(slot.generated == generated)
        #expect(slot.dispatchStart == generated + 2 * Self.ms)
        #expect(slot.presented == generated + 9 * Self.ms)
        for stage in InputStage.allCases where ![InputStage.generated, .dispatchStart, .presented].contains(stage) {
            #expect(slot[stage] == 0, "stage \(stage) was never marked")
        }
    }

    @Test func aClosedOrReusedTokenWritesNothing() throws {
        let table = InputLatencySlotTable(capacity: 1)
        let first = try #require(table.begin(kind: .mousePress, target: .layout, entrypoint: .person, generated: Self.ms))
        _ = try #require(table.close(first))
        #expect(table.close(first) == nil, "a slot closes once")
        #expect(!table.mark(first, .dispatchEnd, at: 2 * Self.ms), "a closed slot takes no mark")
        let second = try #require(table.begin(kind: .keyRelease, target: .palette, entrypoint: .automation, generated: 5 * Self.ms))
        #expect(second.index == first.index, "a one-entry table reuses its entry")
        #expect(second != first, "a reused entry has a new generation")
        #expect(!table.mark(first, .dispatchEnd, at: 6 * Self.ms), "the old token must not write into the new input")
        #expect(!table.setCausedFrameUpdate(first))
        #expect(!table.addCoalesced(first, 3))
        let slot = try #require(table.close(second))
        #expect(slot.kind == .keyRelease)
        #expect(slot.target == .palette)
        #expect(slot.entrypoint == .automation)
        #expect(slot.dispatchEnd == 0)
        #expect(!slot.causedFrameUpdate)
        #expect(slot.coalescedCount == 1)
    }

    @Test func metaFieldsRoundTrip() throws {
        let table = InputLatencySlotTable()
        let token = try #require(table.begin(kind: .scrollFirstUpdate, target: .chromiumPage, entrypoint: .person, generated: Self.ms))
        #expect(table.setPresentationSource(token, .hostFeedback))
        #expect(table.setCausedFrameUpdate(token))
        #expect(table.addCoalesced(token, 4))
        #expect(table.addCoalesced(token, UInt16.max), "the count saturates")
        let slot = try #require(table.close(token))
        #expect(slot.kind == .scrollFirstUpdate)
        #expect(slot.target == .chromiumPage)
        #expect(slot.presentationSource == .hostFeedback)
        #expect(slot.causedFrameUpdate)
        #expect(slot.coalescedCount == UInt16.max)
    }

    @Test func variableRefreshAndAStageReadBackWhileOpen() throws {
        let table = InputLatencySlotTable()
        let token = try #require(table.begin(kind: .keyPress, target: .terminal, entrypoint: .automation, generated: Self.ms))
        #expect(table.time(token, .contentSubmitted) == nil, "not stamped yet")
        #expect(table.mark(token, .contentSubmitted, at: 3 * Self.ms))
        #expect(table.time(token, .contentSubmitted) == 3 * Self.ms)
        #expect(table.time(token, .generated) == Self.ms)
        #expect(table.setVariableRefresh(token))
        #expect(table.setPresentationSource(token, .nominalRefresh))
        let slot = try #require(table.close(token))
        #expect(slot.isVariableRefresh && slot.presentationSource == .nominalRefresh)
        #expect(slot.entrypoint == .automation, "the variable-refresh bit is not the entrypoint's")
        #expect(table.time(token, .contentSubmitted) == nil, "a closed slot reads nothing")
    }

    @Test func everyKindTargetAndSourceRoundTrips() throws {
        let table = InputLatencySlotTable()
        for kind in InputEventKind.allCases {
            for target in InputTarget.allCases {
                for source in InputPresentationSource.allCases {
                    let token = try #require(table.begin(kind: kind, target: target, entrypoint: .automation, generated: 7))
                    table.setPresentationSource(token, source)
                    let slot = try #require(table.close(token))
                    #expect(slot.kind == kind && slot.target == target && slot.presentationSource == source
                        && slot.entrypoint == .automation)
                }
            }
        }
    }

    @Test func anInputWithNoEventTimeIsNotTracked() {
        let table = InputLatencySlotTable()
        #expect(table.begin(kind: .keyPress, target: .other, entrypoint: .person, generated: 0) == nil)
        #expect(table.droppedCount == 0, "an untimed event is not a full table")
    }

    @Test func aFullTableDropsAndCounts() throws {
        let table = InputLatencySlotTable()
        #expect(table.capacity == 128)
        var tokens: [InputLatencyToken] = []
        for offset in 0..<UInt64(table.capacity) {
            let token = try #require(table.begin(kind: .drag, target: .layout, entrypoint: .person, generated: Self.ms + offset))
            tokens.append(token)
        }
        #expect(Set(tokens.map(\.index)).count == table.capacity, "each open slot has its own entry")
        #expect(table.begin(kind: .drag, target: .layout, entrypoint: .person, generated: 2 * Self.ms) == nil)
        #expect(table.begin(kind: .drag, target: .layout, entrypoint: .person, generated: 3 * Self.ms) == nil)
        #expect(table.droppedCount == 2)
        _ = try #require(table.close(tokens[40]))
        let reused = try #require(table.begin(kind: .keyPress, target: .terminal, entrypoint: .person, generated: 4 * Self.ms))
        #expect(reused.index == tokens[40].index, "the one free entry is found")
        #expect(table.droppedCount == 2)
    }

    /// Three lanes stamp stages and a fourth thread closes, each on a thread of its own and all
    /// released together, the lanes marking until the closer is done, so closes land between one
    /// lane's mark and another's. A slot that closes with some lanes' stages stamped and others
    /// skipped proves the four overlapped; over 50 rounds at least one must.
    @Test func stagesFromThreeThreadsAndACloseOnAFourthDoNotRace() async throws {
        let table = InputLatencySlotTable()
        let lanes: [[InputStage]] = [
            [.arrivedMain, .dispatchStart, .textInputStart, .textInputEnd],
            [.dispatchEnd, .mainCommit, .contentSubmitted, .daemonReceived],
            [.ptyWritten, .echoRead, .echoSent, .presented],
        ]
        var overlapped = false
        for round in 0..<UInt64(50) {
            var tokens: [InputLatencyToken] = []
            for offset in 0..<UInt64(table.capacity) {
                let generated = (round * 1_000 + offset + 1) * Self.ms
                let token = try #require(table.begin(kind: .keyPress, target: .terminal, entrypoint: .person, generated: generated))
                tokens.append(token)
            }
            let opened = tokens
            let gate = ThreadGate(threads: lanes.count + 1)
            var bodies: [@Sendable () -> Void] = []
            for (laneIndex, lane) in lanes.enumerated() {
                // Each lane starts at its own third of the table, so while the closer walks it the
                // lanes stand at different slots.
                let first = laneIndex * opened.count / lanes.count
                bodies.append {
                    repeat {
                        for step in 0..<opened.count {
                            let offset = (first + step) % opened.count
                            let generated = (round * 1_000 + UInt64(offset) + 1) * Self.ms
                            for stage in lane { table.mark(opened[offset], stage, at: Self.expected(generated, stage)) }
                            table.setCausedFrameUpdate(opened[offset])
                        }
                    } while !gate.closerDone
                }
            }
            bodies.append {
                let ring = InputLatencyRing()
                for token in opened {
                    if let slot = table.close(token) { ring.append(slot) }
                }
                gate.finishClosing(ring.takeBatch())
            }
            await gate.run(bodies)
            let slots = gate.closedSlots
            #expect(slots.count == table.capacity, "every open slot closes exactly once")
            for slot in slots {
                var stamped = false
                var skipped = false
                for stage in InputStage.allCases where stage != .generated && stage != .lastGenerated {
                    let value = slot[stage]
                    if value == 0 { skipped = true } else { stamped = true }
                    #expect(value == 0 || value == Self.expected(slot.generated, stage),
                            "stage \(stage) holds a value no thread wrote for this input")
                }
                if stamped && skipped { overlapped = true }
            }
            for token in opened { #expect(!table.mark(token, .presented, at: 1), "a closed slot takes no late mark") }
        }
        #expect(overlapped, "no slot closed between two lanes' marks: the threads never overlapped")
        #expect(table.droppedCount == 0)
    }

    @Test func marksThatFinishBeforeTheCloseAreAllKept() async throws {
        let table = InputLatencySlotTable()
        let generated = 10 * Self.ms
        let token = try #require(table.begin(kind: .keyPress, target: .terminal, entrypoint: .person, generated: generated))
        let stages = InputStage.allCases.filter { $0 != .generated }
        await withTaskGroup(of: Void.self) { group in
            for stage in stages {
                group.addTask { _ = table.mark(token, stage, at: Self.expected(generated, stage)) }
            }
        }
        let slot = try #require(table.close(token))
        for stage in stages { #expect(slot[stage] == Self.expected(generated, stage)) }
    }

    // MARK: ring

    @Test func theRingRoundsItsCapacityAndHandsOverHalves() {
        #expect(InputLatencyRing().capacity == 256)
        #expect(InputLatencyRing().batchSize == 128)
        #expect(InputLatencyRing(capacity: 5).capacity == 8)
        #expect(InputLatencyRing(capacity: 0).capacity == 2)

        let ring = InputLatencyRing(capacity: 8)
        var handOffs: [Int] = []
        for value in 1...8 {
            if ring.append(Self.slot(UInt64(value))) { handOffs.append(value) }
            if value == 4 {
                #expect(ring.takeBatch().map(\.generated) == [1, 2, 3, 4], "the first half, oldest first")
            }
        }
        #expect(handOffs == [4, 8], "a hand-off each time half the ring fills")
        #expect(ring.takeBatch().map(\.generated) == [5, 6, 7, 8])
        #expect(ring.takeBatch().isEmpty, "a taken slot is not handed over twice")
        #expect(ring.droppedCount == 0)
    }

    @Test func aHandOffCountsFromTheLastTakeAndRepeatsUntilATake() {
        let ring = InputLatencyRing(capacity: 8)
        var handOffs: [Int] = []
        for value in 1...12 {
            if ring.append(Self.slot(UInt64(value))) { handOffs.append(value) }
            if value == 3 { #expect(ring.takeBatch().count == 3, "a take in the middle of a half") }
        }
        #expect(handOffs == [7, 8, 9, 10, 11, 12], "batchSize slots after the take, then each append until a take")
        #expect(ring.takeBatch().map(\.generated) == Array(UInt64(5)...12), "the ring kept the newest capacity slots")
        #expect(ring.droppedCount == 1, "slot 4 was overwritten before a take")
        #expect(!ring.append(Self.slot(13)), "a take resets the count")
    }

    @Test func theRingWrapsAndCountsWhatItOverwrote() {
        let ring = InputLatencyRing(capacity: 8)
        for value in 1...20 { ring.append(Self.slot(UInt64(value))) }
        #expect(ring.appendedCount == 20)
        #expect(ring.recent(3).map(\.generated) == [20, 19, 18], "newest first")
        #expect(ring.recent(50).count == 8)
        #expect(ring.takeBatch().map(\.generated) == Array(UInt64(13)...20), "the kept slots, oldest first")
        #expect(ring.droppedCount == 12, "the slots overwritten before a take")
        for value in 21...23 { ring.append(Self.slot(UInt64(value))) }
        #expect(ring.takeBatch().map(\.generated) == [21, 22, 23])
        #expect(ring.droppedCount == 12)
    }

    private static func slot(_ generated: UInt64) -> InputLatencySlot {
        var slot = InputLatencySlot(kind: .scrollUpdate, target: .sidebar, entrypoint: .person)
        slot.generated = generated
        return slot
    }

    // MARK: buckets

    @Test func bucketEdgesMatchTheSpec() {
        #expect(InputLatencyBuckets.edgesNanos == [1, 2, 4, 6, 8.3, 10, 12, 16.7, 24, 33, 50, 100, 250].map { UInt64(($0 * 1_000_000).rounded()) })
        #expect(InputLatencyBuckets.bucketCount == 14)
        #expect(InputLatencyBuckets.bucket(forNanos: 0) == 0)
        #expect(InputLatencyBuckets.bucket(forNanos: Self.ms) == 0, "an edge belongs to the bucket below it")
        #expect(InputLatencyBuckets.bucket(forNanos: Self.ms + 1) == 1)
        #expect(InputLatencyBuckets.bucket(forNanos: 8_300_000) == 4)
        #expect(InputLatencyBuckets.bucket(forNanos: 8_300_001) == 5)
        #expect(InputLatencyBuckets.bucket(forNanos: 16_700_000) == 7)
        #expect(InputLatencyBuckets.bucket(forNanos: 250 * Self.ms) == 12)
        #expect(InputLatencyBuckets.bucket(forNanos: 250 * Self.ms + 1) == 13, "over the last edge: overflow")
        var buckets = InputLatencyBuckets()
        for nanos in [UInt64(0), 5 * Self.ms, 9 * Self.ms, 9 * Self.ms, UInt64.max] { buckets.record(nanos: nanos) }
        #expect(buckets.total == 5)
        #expect(buckets.counts[0] == 1 && buckets.counts[3] == 1 && buckets.counts[5] == 2 && buckets.counts[13] == 1)
    }
}

/// Runs bodies on threads of their own, releases them together and resumes when all have
/// returned; the closing body hands its slots over with ``finishClosing(_:)``. Dedicated threads, not the cooperative pool, so the start gate's spin cannot starve a
/// body that has not started yet.
private final class ThreadGate: Sendable {
    private let threads: Int
    private let arrived = Atomic<Int>(0)
    private let finished = Atomic<Int>(0)
    private let closed = Atomic<Bool>(false)
    private let done = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let slots = Mutex<[InputLatencySlot]>([])

    init(threads: Int) {
        self.threads = threads
    }

    /// Whether the closing body has finished its walk.
    var closerDone: Bool { closed.load(ordering: .acquiring) }

    /// The slots the closing body handed over.
    var closedSlots: [InputLatencySlot] { slots.withLock { $0 } }

    func finishClosing(_ closedSlots: [InputLatencySlot]) {
        slots.withLock { $0 = closedSlots }
        closed.store(true, ordering: .releasing)
    }

    func run(_ bodies: [@Sendable () -> Void]) async {
        precondition(bodies.count == threads)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            done.withLock { $0 = continuation }
            for body in bodies {
                Thread.detachNewThread { [self] in
                    arrived.wrappingAdd(1, ordering: .acquiringAndReleasing)
                    while arrived.load(ordering: .acquiring) < threads {}
                    body()
                    if finished.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue == threads {
                        done.withLock { $0.take() }?.resume()
                    }
                }
            }
        }
    }
}

