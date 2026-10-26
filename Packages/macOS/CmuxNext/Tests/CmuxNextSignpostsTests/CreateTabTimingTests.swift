import CmuxNextCompat
import CoreFoundation
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `create.tab` (p09-observability task 030): a ``CreateTabInterval`` is one ring async pair keyed by its intent id,
/// begun with the kind's code and ended exactly once with the outcome (0 shown, 1 closed); the stand-in commit is an
/// instant with the kind and the same id. Each test records into its own ``TraceRuntime`` and mirror.
@MainActor @Suite(.serialized)
struct CreateTabTimingTests {
    private let mirror = SignpostMetricKitMirror()

    /// A `create` signposter on a runtime with the `create` category on (or off) that keeps its records.
    private func signposter(createOn: Bool = true) -> (Signposter, CreateRecordLog) {
        let log = CreateRecordLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(createOn ? 1 << UInt64(SignpostCategory.create.traceBit) : 0)
        return (Signposter(category: .create, mirror: mirror, trace: runtime), log)
    }

    /// Runs one main run-loop turn that polls and exits without waiting: its exit fires the commit boundary.
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test func aShownTabIsOnePairKeyedByItsIntentIDWithTheStandInInstantBetween() throws {
        let (create, log) = signposter()
        let interval = CreateTabInterval(kind: .chromium, signposter: create)
        #expect(log.phases == [.asyncBegin], "the intent's turn writes the AB")
        let begin = try #require(log.records.first)
        #expect(begin.name == SignpostName.createTab.rawValue)
        #expect(begin.arg0 == CreateTabInterval.Kind.chromium.traceCode, "the AB holds the kind")
        #expect(begin.arg1 == interval.intentID, "the pair is keyed by the intent id")

        interval.standInShown()
        #expect(log.phases == [.asyncBegin], "the instant waits for the stand-in's commit")
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .instant])
        #expect(log.records[1].arg0 == CreateTabInterval.Kind.chromium.traceCode)
        #expect(log.records[1].arg1 == interval.intentID, "the instant names the same intent")

        interval.end(.shown)
        #expect(log.phases == [.asyncBegin, .instant, .asyncEnd])
        #expect(log.records[2].arg0 == CreateTabInterval.Outcome.shown.rawValue)
        #expect(log.records[2].arg1 == interval.intentID)
        #expect(!interval.isOpen)
        #expect(interval.outcome == .shown)
    }

    @Test func aTabClosedBeforeItsFirstFrameEndsOnceAsClosed() {
        let (create, log) = signposter()
        let interval = CreateTabInterval(kind: .terminal, signposter: create)
        interval.standInShown()
        interval.end(.closed)
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd], "no stand-in instant after the end")
        #expect(log.records.last?.arg0 == CreateTabInterval.Outcome.closed.rawValue)
        interval.end(.shown)
        #expect(log.records.count == 2, "a later end writes nothing")
        #expect(interval.outcome == .closed, "the first end stays")
    }

    @Test(arguments: CreateTabInterval.Kind.allCases)
    func eachKindEndsExactlyOnceShownOrClosed(_ kind: CreateTabInterval.Kind) {
        for outcome in [CreateTabInterval.Outcome.shown, .closed] {
            let (create, log) = signposter()
            let interval = CreateTabInterval(kind: kind, signposter: create)
            interval.end(outcome)
            interval.end(outcome == .shown ? .closed : .shown)
            #expect(log.phases == [.asyncBegin, .asyncEnd], "\(kind) \(outcome)")
            #expect(log.records.first?.arg0 == kind.traceCode)
            #expect(log.records.last?.arg0 == outcome.rawValue)
            #expect(log.records.first?.arg1 == log.records.last?.arg1, "one async id pairs the AB and the AE")
        }
    }

    @Test func kindCodesAreFixedNonzeroAndDistinct() {
        #expect(CreateTabInterval.Kind.allCases.map(\.traceCode) == [1, 2, 3, 4, 5])
        #expect(CreateTabInterval.Kind.allCases.map(\.name) == ["terminal", "chromium", "webkit", "chat", "page"])
    }

    @Test func twoOverlappingCreatesKeepTheirOwnIDs() {
        let (create, log) = signposter()
        let first = CreateTabInterval(kind: .terminal, signposter: create)
        let second = CreateTabInterval(kind: .webkit, signposter: create)
        #expect(first.intentID != second.intentID)
        first.end(.shown)
        second.end(.closed)
        let ends = log.records.filter { $0.phase == .asyncEnd }
        #expect(ends.map(\.arg1) == [first.intentID, second.intentID])
        #expect(ends.map(\.arg0) == [0, 1])
    }

    @Test func withTheCategoryOffNothingIsRecordedAndTheIntervalStillEndsOnce() {
        let (create, log) = signposter(createOn: false)
        let interval = CreateTabInterval(kind: .page, signposter: create)
        interval.standInShown()
        pollingTurn()
        interval.end(.shown)
        #expect(log.records.isEmpty)
        #expect(!interval.isOpen)
    }
}

/// The records a test runtime's stub writes, in order.
private nonisolated final class CreateRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    var phases: [TraceRuntime.Phase] { records.map(\.phase) }
}
