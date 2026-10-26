import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `switch.tab` (p09-observability task 028): one async pair per tab switch, begun at the intent with the kind and the
/// destination, ended at the commit of that destination's content (`end=page_activated` when a Chromium page window
/// showed it). The boundary is a seam the test fires, and each test records into its own ``TraceRuntime``.
@MainActor
@Suite struct TabSwitchTimingTests {
    /// The records a test runtime writes, in order.
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])
        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime that records into this log, with the switch category on.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.switch.traceBit))
            return runtime
        }
    }

    /// Commit boundaries asked for and not fired yet.
    @MainActor
    private final class Boundaries {
        var waiting: [@MainActor (CommitBoundary.Outcome) -> Void] = []
        func fire(_ outcome: CommitBoundary.Outcome = .committed) {
            let due = waiting
            waiting = []
            for body in due { body(outcome) }
        }
    }

    private final class Pane {}

    private let log = RecordLog()
    private let boundaries = Boundaries()
    private let pane = Pane()

    private func makeSignpost() -> TabSwitchSignpost {
        let signposter = Signposter(category: .switch, mirror: SignpostMetricKitMirror(), trace: log.runtime())
        let boundaries = boundaries
        return TabSwitchSignpost(signposter: signposter) { boundaries.waiting.append($0) }
    }

    private var tabRecords: [TraceRuntime.StubRecord] {
        log.records.filter { $0.name == SignpostName.switchTab.rawValue }
    }

    /// The (begin, end) pairs of the records, matched by async id; fails on an end without a begin.
    private func pairs() -> [(begin: TraceRuntime.StubRecord, end: TraceRuntime.StubRecord?)] {
        var result: [(begin: TraceRuntime.StubRecord, end: TraceRuntime.StubRecord?)] = []
        for record in tabRecords {
            switch record.phase {
            case .asyncBegin: result.append((record, nil))
            case .asyncEnd:
                let index = result.firstIndex { $0.begin.arg1 == record.arg1 && $0.end == nil }
                #expect(index != nil, "an end without its begin")
                if let index { result[index].end = record }
            default: Issue.record("switch.tab wrote phase \(record.phase)")
            }
        }
        return result
    }

    @Test("A warm switch is one pair, ended at the commit after its content was shown, with its kind and input age")
    func warmSwitchIsOnePair() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .warm, inputAgeMilliseconds: 2.5)
        signpost.contentShown(pane, key: "b")
        #expect(pairs().count == 1)
        #expect(pairs().first?.end == nil)
        boundaries.fire()
        let pair = try #require(pairs().first)
        #expect(pairs().count == 1)
        #expect(pair.begin.arg0 & 0xFF == TabSwitchSignpost.Kind.warm.rawValue)
        #expect(pair.begin.arg0 >> 40 == 2_500)
        #expect(pair.end?.arg0 == Signposter.EndCode.ended)
        #expect(signpost.openCount == 0)
    }

    @Test("Each kind writes its code: cold 0, warm 1, page 2; no input event writes all ones in the age bits")
    func kindCodes() {
        let signpost = makeSignpost()
        for kind in TabSwitchSignpost.Kind.allCases {
            signpost.began(pane, to: "b", kind: kind, inputAgeMilliseconds: -1)
            signpost.contentShown(pane, key: "b")
            boundaries.fire()
        }
        let begins = pairs().map(\.begin.arg0)
        #expect(begins.map { $0 & 0xFF } == [0, 1, 2])
        #expect(begins.allSatisfy { $0 >> 40 == 0xFF_FFFF })
        #expect(pairs().allSatisfy { $0.end?.arg0 == Signposter.EndCode.ended })
    }

    @Test("A re-show of another tab (a store change, the tab already shown) ends nothing; the destination's show does")
    func onlyTheDestinationEndsTheSwitch() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .cold, inputAgeMilliseconds: -1)
        signpost.contentShown(pane, key: "a")
        #expect(signpost.pageShow(pane, key: "a") == nil)
        #expect(boundaries.waiting.isEmpty)
        signpost.contentShown(pane, key: "b")
        boundaries.fire()
        #expect(pairs().count == 1)
        #expect(pairs().first?.end?.arg0 == Signposter.EndCode.ended)
    }

    @Test("A Chromium page shown in the switch's turn ends it as page activated, at that turn's commit, once")
    func pageSwitchEndsPageActivated() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .page, inputAgeMilliseconds: 1)
        let show = try #require(signpost.pageShow(pane, key: "b"))
        show.pageShown()
        show.pageShown()
        signpost.contentShown(pane, key: "b")
        #expect(boundaries.waiting.count == 1)
        boundaries.fire()
        #expect(pairs().count == 1)
        #expect(pairs().first?.end?.arg0 == Signposter.EndCode.pageActivated)
    }

    @Test("A page whose page window did not show it in the turn ends at the pane's commit; a later show writes nothing")
    func pageNotShownEndsAtThePaneCommit() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .page, inputAgeMilliseconds: -1)
        let show = try #require(signpost.pageShow(pane, key: "b"))
        signpost.contentShown(pane, key: "b")
        boundaries.fire()
        show.pageShown()
        #expect(boundaries.waiting.isEmpty)
        #expect(pairs().count == 1)
        #expect(pairs().first?.end?.arg0 == Signposter.EndCode.ended)
    }

    @Test("A page activated in a turn whose commit the boundary missed ends as missed")
    func pageActivatedButMissed() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .page, inputAgeMilliseconds: -1)
        try #require(signpost.pageShow(pane, key: "b")).pageShown()
        boundaries.fire(.missed)
        #expect(pairs().first?.end?.arg0 == Signposter.EndCode.missed)
    }

    @Test("A second intent ends the open switch as missed: 2 pairs, the stale page show writes nothing")
    func supersededSwitchEndsMissed() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .page, inputAgeMilliseconds: -1)
        let stale = try #require(signpost.pageShow(pane, key: "b"))
        signpost.began(pane, to: "c", kind: .warm, inputAgeMilliseconds: -1)
        stale.pageShown()
        #expect(boundaries.waiting.isEmpty)
        signpost.contentShown(pane, key: "c")
        boundaries.fire()
        let all = pairs()
        try #require(all.count == 2)
        #expect(all[0].end?.arg0 == Signposter.EndCode.missed)
        #expect(all[1].end?.arg0 == Signposter.EndCode.ended)
    }

    @Test("A switch superseded while its boundary is in flight ends once, as missed")
    func supersededWhileEnding() throws {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .warm, inputAgeMilliseconds: -1)
        signpost.contentShown(pane, key: "b")
        signpost.began(pane, to: "c", kind: .cold, inputAgeMilliseconds: -1)
        boundaries.fire()
        let all = pairs()
        try #require(all.count == 2)
        #expect(all[0].end?.arg0 == Signposter.EndCode.missed)
        #expect(all[1].end == nil)
        #expect(signpost.openCount == 1)
    }

    @Test("Showing content twice in one switch ends it once; a missed commit ends it as missed")
    func oneEndPerSwitch() {
        let signpost = makeSignpost()
        signpost.began(pane, to: "b", kind: .cold, inputAgeMilliseconds: -1)
        signpost.contentShown(pane, key: "b")
        signpost.contentShown(pane, key: "b")
        #expect(boundaries.waiting.count == 1)
        boundaries.fire(.missed)
        #expect(pairs().count == 1)
        #expect(pairs().first?.end?.arg0 == Signposter.EndCode.missed)
        signpost.contentShown(pane, key: "b")
        #expect(boundaries.waiting.isEmpty)
    }

    @Test("A pane that goes away or hides ends its open switch as missed; content shown without an intent writes nothing")
    func forgetAndNoIntent() {
        let signpost = makeSignpost()
        signpost.contentShown(pane, key: "b")
        #expect(signpost.pageShow(pane, key: "b") == nil)
        #expect(tabRecords.isEmpty)
        signpost.began(pane, to: "b", kind: .warm, inputAgeMilliseconds: -1)
        signpost.forget(pane)
        signpost.forget(pane)
        // The pane draws again and shows the tab: the forgotten switch writes no committed end.
        signpost.contentShown(pane, key: "b")
        #expect(boundaries.waiting.isEmpty)
        #expect(pairs().count == 1)
        #expect(pairs().first?.end?.arg0 == Signposter.EndCode.missed)
        #expect(signpost.openCount == 0)
    }

    @Test("Switches of two panes are separate pairs")
    func panesAreSeparate() {
        let signpost = makeSignpost()
        let other = Pane()
        signpost.began(pane, to: "b", kind: .warm, inputAgeMilliseconds: -1)
        signpost.began(other, to: "b", kind: .cold, inputAgeMilliseconds: -1)
        signpost.contentShown(other, key: "b")
        signpost.contentShown(pane, key: "b")
        boundaries.fire()
        #expect(pairs().count == 2)
        #expect(pairs().allSatisfy { $0.end?.arg0 == Signposter.EndCode.ended })
    }

    @Test("With the switch category off, a switch writes no record")
    func offWritesNothing() {
        let runtime = TraceRuntime(role: .app)
        let signpost = TabSwitchSignpost(signposter: Signposter(category: .switch, mirror: SignpostMetricKitMirror(), trace: runtime)) { $0(.committed) }
        signpost.began(pane, to: "b", kind: .warm, inputAgeMilliseconds: -1)
        signpost.contentShown(pane, key: "b")
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        #expect(signpost.openCount == 0)
    }
}
