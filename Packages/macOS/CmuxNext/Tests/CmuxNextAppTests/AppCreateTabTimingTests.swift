import CmuxNextCompat
@testable import CmuxNextApp
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The app's `create.tab` waits (p09-observability task 030, ``CreateTabTimings``): a new tab's interval ends exactly
/// once, at the first frame of the content its pane shows, or as closed when the tab closes first, whichever key the
/// tab has by then (a stand-in's, or the daemon tab's that took its place). Each test records into its own
/// ``TraceRuntime``; contents are fakes that report their first frame when the test says.
@MainActor @Suite(.serialized)
struct AppCreateTabTimingTests {
    /// A content's first frame, reported when the test calls ``show()`` or ``close()``.
    @MainActor final class FakeContent {
        private(set) var done: (@MainActor (CreateTabInterval.Outcome) -> Void)?
        private(set) var waits = 0
        private(set) var cancels = 0

        var firstFrame: CreateTabTimings.FirstFrame {
            .init(content: ObjectIdentifier(self)) { [self] done in
                waits += 1
                self.done = done
                return { [self] in cancels += 1 }
            }
        }

        func show() { done?(.shown) }
        func close() { done?(.closed) }
    }

    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

        /// The create.tab ends, in order: (async id, outcome).
        var ends: [(id: UInt64, outcome: UInt64)] {
            records.filter { $0.name == SignpostName.createTab.rawValue && $0.phase == .asyncEnd }.map { ($0.arg1, $0.arg0) }
        }

        var begins: Int { records.filter { $0.name == SignpostName.createTab.rawValue && $0.phase == .asyncBegin }.count }
    }

    private func timings() -> (CreateTabTimings, RecordLog) {
        let log = RecordLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.create.traceBit))
        return (CreateTabTimings(signposter: Signposter(category: .create, trace: runtime)), log)
    }

    @Test(arguments: CreateTabInterval.Kind.allCases)
    func eachKindEndsOnceAtItsContentsFirstFrame(_ kind: CreateTabInterval.Kind) {
        let (timings, log) = timings()
        let interval = timings.begin(kind)
        timings.expect(interval, tab: "tab-1", standIn: false)
        let content = FakeContent()
        timings.presented("tab-1", firstFrame: content.firstFrame)
        #expect(log.ends.isEmpty, "the interval waits for the first frame")
        content.show()
        #expect(log.ends.map(\.outcome) == [CreateTabInterval.Outcome.shown.rawValue])
        #expect(log.ends.first?.id == interval.intentID)
        // Later events of the same tab end nothing again.
        timings.presented("tab-1", firstFrame: content.firstFrame)
        content.show()
        timings.released("tab-1")
        #expect(log.ends.count == 1)
        #expect(content.waits == 1, "one wait per created tab")
        #expect(timings.waitingTabs.isEmpty)
    }

    @Test(arguments: CreateTabInterval.Kind.allCases)
    func eachKindClosedBeforeItsFirstFrameEndsOnceAsClosed(_ kind: CreateTabInterval.Kind) {
        let (timings, log) = timings()
        // Closed before its content showed.
        let unshown = timings.begin(kind)
        timings.expect(unshown, tab: "tab-1", standIn: true)
        timings.released("tab-1")
        // Closed while its content waited for a frame: the wait is cancelled.
        let waiting = timings.begin(kind)
        timings.expect(waiting, tab: "tab-2", standIn: true)
        let content = FakeContent()
        timings.presented("tab-2", firstFrame: content.firstFrame)
        timings.released("tab-2")
        #expect(content.cancels == 1)
        content.show() // a frame after the close ends nothing
        // The content itself closed (a page closed by its engine).
        let closing = timings.begin(kind)
        timings.expect(closing, tab: "tab-3", standIn: false)
        let other = FakeContent()
        timings.presented("tab-3", firstFrame: other.firstFrame)
        other.close()
        timings.released("tab-3")

        #expect(log.begins == 3)
        #expect(log.ends.map(\.id) == [unshown.intentID, waiting.intentID, closing.intentID])
        #expect(log.ends.allSatisfy { $0.outcome == CreateTabInterval.Outcome.closed.rawValue })
        #expect(timings.waitingTabs.isEmpty)
    }

    @Test func theDaemonTabThatTakesAStandInsPlaceKeepsItsWait() {
        let (timings, log) = timings()
        let interval = timings.begin(.chromium)
        timings.expect(interval, tab: "pending_tab_1", standIn: true)
        timings.rekey("pending_tab_1", to: "tab_real")
        // The stand-in's release on the move (displacing nothing) is gone: the daemon tab's close ends it.
        timings.released("pending_tab_1")
        #expect(log.ends.isEmpty)
        timings.released("tab_real")
        #expect(log.ends.map(\.outcome) == [CreateTabInterval.Outcome.closed.rawValue])
    }

    @Test func theSameContentShownUnderTheDaemonTabsIDMovesTheWait() {
        let (timings, log) = timings()
        let interval = timings.begin(.chat)
        timings.expect(interval, tab: "pending_tab_1", standIn: true)
        let content = FakeContent()
        timings.presented("pending_tab_1", firstFrame: content.firstFrame)
        timings.presented("tab_real", firstFrame: content.firstFrame)
        #expect(timings.waitingTabs == ["tab_real"])
        #expect(content.waits == 1, "the move starts no second wait")
        timings.released("tab_real")
        #expect(log.ends.map(\.outcome) == [CreateTabInterval.Outcome.closed.rawValue])
        content.show()
        #expect(log.ends.count == 1)
    }

    @Test func otherContentShownMeanwhileTouchesNoWait() {
        let (timings, log) = timings()
        let interval = timings.begin(.terminal)
        timings.expect(interval, tab: "tab-1", standIn: false)
        timings.presented("tab-other", firstFrame: FakeContent().firstFrame)
        #expect(timings.waitingTabs == ["tab-1"])
        let content = FakeContent()
        timings.presented("tab-1", firstFrame: content.firstFrame)
        content.show()
        #expect(log.ends.map(\.outcome) == [CreateTabInterval.Outcome.shown.rawValue])
    }

    @Test func aContentThatShowedAlreadyEndsAtOnce() {
        let (timings, log) = timings()
        let interval = timings.begin(.webkit)
        timings.expect(interval, tab: "tab-1", standIn: false)
        let page = FakeContent()
        let painted = CreateTabTimings.FirstFrame(content: ObjectIdentifier(page)) { done in
            done(.shown)
            return nil
        }
        timings.presented("tab-1", firstFrame: painted)
        #expect(log.ends.map(\.outcome) == [CreateTabInterval.Outcome.shown.rawValue])
        #expect(timings.waitingTabs.isEmpty)
    }
}
