import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

extension CreateTabTimingTests {
    /// The `create.tab` waits (p09-observability task 030, ``CreateTabTimings``): a new tab's interval ends exactly
    /// once, at the first frame of the content its pane shows (at the commit that shows it when the frame exists
    /// already), as closed when the tab closes first, as hidden when it stops showing first, whichever key the tab
    /// has by then (a stand-in's, the daemon tab's that took its place, or the surface the store lists later).
    /// Each test records into its own ``TraceRuntime`` and fires its own commits; contents are fakes that report
    /// their first frame when the test says.
    @MainActor @Suite(.serialized)
    struct Waits {
        /// A content's first frame, reported when the test calls ``show()`` or ``close()``.
        @MainActor final class FakeContent {
            private(set) var done: (@MainActor (CreateTabInterval.Outcome) -> Void)?
            private(set) var waits = 0
            private(set) var cancels = 0

            var firstFrame: CreateTabTimings.FirstFrame {
                .init(content: self) { [self] done in
                    waits += 1
                    self.done = done
                    return { [self] in cancels += 1 }
                }
            }

            func show() { done?(.shown) }
            func close() { done?(.closed) }
        }

        /// A view with no frame signal that the test lets go of.
        final class Retired {}

        /// The commit boundaries asked for, fired when the test says.
        @MainActor final class Commits {
            private var pending: [@MainActor (CommitBoundary.Outcome) -> Void] = []
            var count: Int { pending.count }

            var afterCommit: CreateTabTimings.AfterCommit { { [self] body in pending.append(body) } }

            func fire(_ outcome: CommitBoundary.Outcome = .committed) {
                let bodies = pending
                pending = []
                for body in bodies { body(outcome) }
            }
        }

        nonisolated final class RecordLog: Sendable {
            private let state = Mutex<[TraceRuntime.StubRecord]>([])

            var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

            func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

            /// The create.tab ends, in order: (async id, outcome).
            var ends: [(id: UInt64, outcome: UInt64)] {
                records.filter { $0.name == SignpostName.createTab.rawValue && $0.phase == .asyncEnd }.map { ($0.arg1, $0.arg0) }
            }

            var outcomes: [UInt64] { ends.map(\.outcome) }

            var begins: Int { records.filter { $0.name == SignpostName.createTab.rawValue && $0.phase == .asyncBegin }.count }

            var instants: Int { records.filter { $0.name == SignpostName.createTab.rawValue && $0.phase == .instant }.count }
        }

        private func timings() -> (CreateTabTimings, RecordLog, Commits) {
            let log = RecordLog()
            let commits = Commits()
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.create.traceBit))
            return (CreateTabTimings(signposter: Signposter(category: .create, trace: runtime), afterCommit: commits.afterCommit), log, commits)
        }

        private static let shown = CreateTabInterval.Outcome.shown.rawValue
        private static let closed = CreateTabInterval.Outcome.closed.rawValue
        private static let hidden = CreateTabInterval.Outcome.hidden.rawValue
        private static let missed = CreateTabInterval.Outcome.missed.rawValue

        @Test(arguments: CreateTabInterval.Kind.allCases)
        func eachKindEndsOnceAtItsContentsFirstFrame(_ kind: CreateTabInterval.Kind) {
            let (timings, log, _) = timings()
            let interval = timings.begin(kind)
            timings.expect(interval, tab: "tab-1", standIn: false)
            let content = FakeContent()
            timings.presented("tab-1", firstFrame: content.firstFrame)
            #expect(log.ends.isEmpty, "the interval waits for the first frame")
            content.show()
            #expect(log.outcomes == [Self.shown])
            #expect(log.ends.first?.id == interval.intentID)
            // Later events of the same tab end nothing again.
            timings.presented("tab-1", firstFrame: content.firstFrame)
            content.show()
            timings.released("tab-1")
            timings.hidden("tab-1")
            #expect(log.ends.count == 1)
            #expect(content.waits == 1, "one wait per created tab")
            #expect(timings.waitingTabs.isEmpty)
        }

        @Test(arguments: CreateTabInterval.Kind.allCases)
        func eachKindClosedBeforeItsFirstFrameEndsOnceAsClosed(_ kind: CreateTabInterval.Kind) {
            let (timings, log, _) = timings()
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
            #expect(log.outcomes.allSatisfy { $0 == Self.closed })
            #expect(timings.waitingTabs.isEmpty)
        }

        /// Chrome's `ContentToVisibleTimeReporter::TabWasHidden`: a tab hidden before its frame ends with no sample,
        /// and its content stops waiting (a hidden terminal's frame client goes idle).
        @Test func aTabHiddenBeforeItsFirstFrameEndsOnceAsHiddenAndCancelsItsWait() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.terminal)
            timings.expect(interval, tab: "tab-1", standIn: false)
            let content = FakeContent()
            timings.presented("tab-1", firstFrame: content.firstFrame)
            timings.hidden("tab-1")
            #expect(content.cancels == 1)
            content.show() // shown again minutes later: no create latency
            timings.presented("tab-1", firstFrame: content.firstFrame)
            #expect(log.outcomes == [Self.hidden])
            #expect(interval.outcome == .hidden)
            #expect(!timings.isWaiting)
        }

        @Test func aSwitchPresentsTheNewTabThenHidesThePreviousOne() {
            let (timings, log, _) = timings()
            let first = timings.begin(.terminal)
            timings.expect(first, tab: "tab-1", standIn: false)
            let content = FakeContent()
            timings.switched(from: nil, to: "tab-1", firstFrame: content.firstFrame)
            let second = timings.begin(.webkit)
            timings.expect(second, tab: "tab-2", standIn: false)
            let page = FakeContent()
            timings.switched(from: "tab-1", to: "tab-2", firstFrame: page.firstFrame)
            #expect(log.ends.map(\.id) == [first.intentID])
            #expect(log.outcomes == [Self.hidden])
            page.show()
            #expect(log.outcomes == [Self.hidden, Self.shown])
        }

        @Test func aStandInsContentShownUnderTheDaemonTabSurvivesTheSwitch() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.terminal)
            timings.expect(interval, tab: "pending_tab_1", standIn: true)
            let content = FakeContent()
            timings.switched(from: nil, to: "pending_tab_1", firstFrame: content.firstFrame)
            timings.switched(from: "pending_tab_1", to: "tab_real", firstFrame: content.firstFrame)
            #expect(timings.waitingTabs == ["tab_real"], "the swap is no hide")
            content.show()
            #expect(log.outcomes == [Self.shown])
        }

        @Test func theDaemonTabThatTakesAStandInsPlaceKeepsItsWait() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.chromium)
            timings.expect(interval, tab: "pending_tab_1", standIn: true)
            timings.rekey("pending_tab_1", to: "tab_real")
            // The stand-in's release on the move (displacing nothing) is gone: the daemon tab's close ends it.
            timings.released("pending_tab_1")
            #expect(log.ends.isEmpty)
            timings.released("tab_real")
            #expect(log.outcomes == [Self.closed])
        }

        @Test func theSameContentShownUnderTheDaemonTabsIDMovesTheWait() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.chat)
            timings.expect(interval, tab: "pending_tab_1", standIn: true)
            let content = FakeContent()
            timings.presented("pending_tab_1", firstFrame: content.firstFrame)
            timings.presented("tab_real", firstFrame: content.firstFrame)
            #expect(timings.waitingTabs == ["tab_real"])
            #expect(content.waits == 1, "the move starts no second wait")
            timings.released("tab_real")
            #expect(log.outcomes == [Self.closed])
            content.show()
            #expect(log.ends.count == 1)
        }

        @Test func otherContentShownMeanwhileTouchesNoWait() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.terminal)
            timings.expect(interval, tab: "tab-1", standIn: false)
            timings.presented("tab-other", firstFrame: FakeContent().firstFrame)
            #expect(timings.waitingTabs == ["tab-1"])
            let content = FakeContent()
            timings.presented("tab-1", firstFrame: content.firstFrame)
            content.show()
            #expect(log.outcomes == [Self.shown])
        }

        /// Chrome ends at the presented frame: a frame that exists already reaches the screen with the commit that
        /// shows the content, not in the show's turn.
        @Test(arguments: [false, true])
        func aContentThatShowedAlreadyEndsAtTheCommitThatShowsIt(_ noSignal: Bool) {
            let (timings, log, commits) = timings()
            let interval = timings.begin(.webkit)
            timings.expect(interval, tab: "tab-1", standIn: false)
            let page = FakeContent()
            let signalled = CreateTabTimings.FirstFrame(content: page) { done in
                done(.shown)
                return nil
            }
            let painted = noSignal ? CreateTabTimings.FirstFrame.atCommit(page) : signalled
            timings.presented("tab-1", firstFrame: painted)
            #expect(log.ends.isEmpty, "the show's turn has not committed")
            #expect(commits.count == 1)
            commits.fire()
            #expect(log.outcomes == [Self.shown])
            #expect(timings.waitingTabs.isEmpty)
        }

        /// A commit boundary asked for during a before-waiting callout fires after the run loop slept: no sample.
        @Test func aMissedCommitEndsAsMissedWithNoStandInInstant() {
            let (timings, log, commits) = timings()
            let interval = timings.begin(.chat)
            timings.expect(interval, tab: "tab-1", standIn: true)
            timings.presented("tab-1", firstFrame: .atCommit(FakeContent()))
            commits.fire(.missed)
            #expect(log.outcomes == [Self.missed])
            #expect(log.instants == 0, "the stand-in instant would carry a later wake's time")
            #expect(!timings.isWaiting)
        }

        @Test func aTabHiddenBeforeTheCommitThatShowsItEndsAsHidden() {
            let (timings, log, commits) = timings()
            let interval = timings.begin(.page)
            timings.expect(interval, tab: "tab-1", standIn: false)
            timings.presented("tab-1", firstFrame: .atCommit(FakeContent()))
            timings.hidden("tab-1")
            commits.fire()
            #expect(log.outcomes == [Self.hidden])
        }

        @Test func aTabThatWillNotShowBeginsNoInterval() {
            let (timings, log, _) = timings()
            #expect(timings.begin(.terminal, shows: false) == nil)
            #expect(log.begins == 0)
            #expect(timings.begin(.terminal, shows: true)?.isOpen == true)
            #expect(log.begins == 1)
        }

        @Test func theStandInInstantGoesAtItsCommit() {
            let (timings, log, commits) = timings()
            timings.expect(timings.begin(.terminal), tab: "tab-1", standIn: true)
            #expect(log.instants == 0)
            commits.fire()
            #expect(log.instants == 1)
        }

        /// The daemon's reply often comes before the store lists its tab: the wait is the surface's until the pane
        /// lists it, then the tab's, and a shown tab is a shown sample.
        @Test func aSurfaceWaitBecomesTheTabsWhenThePaneListsIt() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.terminal)
            timings.expect(interval, surface: 42)
            #expect(timings.waitingSurfaces == [42])
            #expect(!timings.isWaiting)
            timings.listed(surface: 42, tab: "tab-42")
            #expect(timings.waitingTabs == ["tab-42"])
            #expect(timings.waitingSurfaces.isEmpty)
            let content = FakeContent()
            timings.presented("tab-42", firstFrame: content.firstFrame)
            content.show()
            #expect(log.outcomes == [Self.shown])
        }

        @Test func aSurfaceThePaneNeverShowsEndsUnsampled() {
            let (timings, log, _) = timings()
            let dropped = timings.begin(.chromium)
            timings.expect(dropped, surface: 7)
            timings.dropped(surface: 7)
            // A second wait for the same surface closes the first.
            let replaced = timings.begin(.chromium)
            timings.expect(replaced, surface: 8)
            timings.expect(timings.begin(.chromium), surface: 8)
            timings.listed(surface: 99, tab: "other") // no wait for that surface
            #expect(log.ends.map(\.id) == [dropped.intentID, replaced.intentID])
            #expect(log.outcomes == [Self.hidden, Self.closed])
            #expect(timings.waitingSurfaces == [8])
            #expect(timings.waitingTabs.isEmpty)
        }

        /// The wait holds its content weakly: a view retired with no close reported here (a chat whose create failed)
        /// ends its tab as closed at the next show, and a new view at the same address matches no stale wait.
        @Test func aRetiredContentsWaitEndsAsClosed() {
            let (timings, log, _) = timings()
            let interval = timings.begin(.chat)
            timings.expect(interval, tab: "tab-1", standIn: true)
            do {
                let view = Retired()
                timings.presented("tab-1", firstFrame: .init(content: view) { _ in nil })
            }
            let next = FakeContent()
            timings.expect(timings.begin(.terminal), tab: "tab-2", standIn: false)
            timings.presented("tab-2", firstFrame: next.firstFrame)
            #expect(log.ends.map(\.id) == [interval.intentID])
            #expect(log.outcomes == [Self.closed])
            #expect(timings.waitingTabs == ["tab-2"])
        }
    }
}
