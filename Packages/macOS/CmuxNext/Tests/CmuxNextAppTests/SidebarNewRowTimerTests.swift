import CmuxNextCompat
@testable import CmuxNextSidebar
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `create.workspace` (p09-observability task 031): one async pair per new workspace with a row, begun when its
/// create names it (with the input age), ended at the commit boundary after the sidebar pass that drew its row; a
/// row that goes before it was drawn ends the pair as missed. The boundary is a seam the test fires, and each test
/// records into its own ``TraceRuntime``.
@MainActor
@Suite struct SidebarNewRowTimerTests {
    /// The `create.workspace` records a test runtime writes, in order.
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])
        var records: [TraceRuntime.StubRecord] {
            state.withLock { $0 }.filter { $0.name == SignpostName.createWorkspace.rawValue }
        }

        /// A runtime that records into this log, with the create category on.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.create.traceBit))
            return runtime
        }

        /// Each begin's arg0 and its end's code (nil while open), matched by async id.
        var pairs: [(begin: UInt64, end: UInt64?)] {
            var result: [(id: UInt64, begin: UInt64, end: UInt64?)] = []
            for record in records {
                switch record.phase {
                case .asyncBegin: result.append((record.arg1, record.arg0, nil))
                case .asyncEnd:
                    if let index = result.firstIndex(where: { $0.id == record.arg1 && $0.end == nil }) {
                        result[index].end = record.arg0 & 0xFF
                    } else {
                        Issue.record("a create.workspace end without its begin")
                    }
                default: Issue.record("create.workspace wrote phase \(record.phase)")
                }
            }
            return result.map { ($0.begin, $0.end) }
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

    private let log = RecordLog()
    private let boundaries = Boundaries()

    private func makeTimer(inputAge: Double = -1) -> SidebarNewRowTimer {
        let signposter = Signposter(category: .create, mirror: SignpostMetricKitMirror(), trace: log.runtime())
        let boundaries = boundaries
        return SidebarNewRowTimer(signposter: signposter, boundary: { boundaries.waiting.append($0) }, inputAge: { inputAge })
    }

    private func sections(_ ids: String...) -> [SidebarSection] {
        [SidebarSection(kind: .pinned, nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0)) })]
    }

    @Test("A create is one pair: begun with its input age, ended at the commit after its row was drawn")
    func drawnRowEndsAtCommit() throws {
        let timer = makeTimer(inputAge: 3.5)
        timer.began("w1")
        #expect(log.pairs.count == 1)
        timer.drew(sections("w0"), in: nil) // another row: nothing ends
        #expect(boundaries.waiting.isEmpty)
        timer.drew(sections("w0", "w1"), in: nil)
        #expect(log.pairs.first?.end == nil, "it ends at the commit, not at the draw")
        boundaries.fire()
        let pair = try #require(log.pairs.first)
        #expect(log.pairs.count == 1)
        #expect(pair.begin >> 40 == 3_500)
        #expect(pair.end == Signposter.EndCode.ended)
        #expect(timer.openCount == 0)
    }

    @Test("No input event writes all ones in the age bits")
    func noInputEvent() {
        let timer = makeTimer()
        timer.began("w1")
        #expect(log.pairs.first?.begin == 0xFF_FFFF << 40)
    }

    @Test("A second draw of the row in the same turn asks for one boundary; later draws end nothing")
    func oneEndPerCreate() {
        let timer = makeTimer()
        timer.began("w1")
        timer.drew(sections("w1"), in: nil)
        timer.drew(sections("w1"), in: nil)
        #expect(boundaries.waiting.count == 1)
        boundaries.fire()
        timer.drew(sections("w1"), in: nil)
        #expect(boundaries.waiting.isEmpty)
        #expect(log.pairs.count == 1)
        #expect(log.pairs.first?.end == Signposter.EndCode.ended)
    }

    @Test("A row that goes before it was drawn (failed create, close) ends missed; a drawn row's forget changes nothing")
    func forgetEndsMissed() {
        let timer = makeTimer()
        timer.began("gone")
        timer.forget("gone")
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed])
        timer.began("drawn")
        timer.drew(sections("drawn"), in: nil)
        timer.forget("drawn")
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed, Signposter.EndCode.ended])
        #expect(timer.openCount == 0)
    }

    @Test("A boundary that missed the commit ends the pair as missed")
    func missedBoundary() {
        let timer = makeTimer()
        timer.began("w1")
        timer.drew(sections("w1"), in: nil)
        boundaries.fire(.missed)
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.missed])
    }

    @Test("Creates past the open limit end the oldest as missed, so a row that never draws cannot hold its pair forever")
    func openLimit() {
        let timer = makeTimer()
        for index in 0...SidebarNewRowTimer.openLimit { timer.began("w\(index)") }
        #expect(timer.openCount == SidebarNewRowTimer.openLimit)
        #expect(log.pairs.first?.end == Signposter.EndCode.missed)
        #expect(log.pairs.dropFirst().allSatisfy { $0.end == nil })
    }

    @Test("Interleaved creates end each at its own row's commit")
    func interleaved() {
        let timer = makeTimer()
        timer.began("a")
        timer.began("b")
        timer.drew(sections("b"), in: nil)
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [nil, Signposter.EndCode.ended])
        timer.drew(sections("a", "b"), in: nil)
        boundaries.fire()
        #expect(log.pairs.map(\.end) == [Signposter.EndCode.ended, Signposter.EndCode.ended])
    }
}
