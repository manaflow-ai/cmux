import CmuxNextSignposts
@testable import CmuxNextSidebar
import Testing

/// `create.workspace` (p09-observability-031): one async pair per new workspace, from the press to the
/// Core Animation commit that carries its sidebar row, and exactly one end on every path (drawn, removed,
/// no row, missed commit, dropped past the limit).
@MainActor @Suite struct SidebarNewRowTimerTests {
    /// The ring points the timer wrote, and the commit boundaries it asked for (run them with ``commit(_:)``).
    @MainActor final class Recorder {
        /// One ring point: an AB (id, origin) or an AE (id, outcome), as the raw arguments the ring holds.
        enum Point: Equatable {
            case begin(id: UInt64, origin: UInt64)
            case end(id: UInt64, outcome: UInt64)

            static func begin(_ id: UInt64, _ origin: SidebarNewRowTimer.Origin) -> Point { .begin(id: id, origin: origin.rawValue) }
            static func end(_ id: UInt64, _ outcome: SidebarNewRowTimer.Outcome) -> Point { .end(id: id, outcome: outcome.rawValue) }
        }

        var isEnabled = true
        var points: [Point] = []
        var boundaries: [@MainActor (CommitBoundary.Outcome) -> Void] = []

        func timer() -> SidebarNewRowTimer {
            let trace = SidebarNewRowTimer.Trace(
                isEnabled: { [unowned self] in self.isEnabled },
                begin: { [unowned self] id, origin in self.points.append(.begin(id: id, origin: origin)) },
                end: { [unowned self] id, outcome in self.points.append(.end(id: id, outcome: outcome)) }
            )
            return SidebarNewRowTimer(trace: trace) { [unowned self] body in self.boundaries.append(body) }
        }

        /// Runs the boundaries asked for so far, as the turn's commit would.
        func commit(_ outcome: CommitBoundary.Outcome = .committed) {
            let due = boundaries
            boundaries = []
            for body in due { body(outcome) }
        }

        var ends: [Point] { points.filter { if case .end = $0 { true } else { false } } }
    }

    static func sections(_ ids: String...) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                        nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0)) })]
    }

    @Test func aPressEndsAtTheCommitThatDrawsItsRow() {
        let recorder = Recorder(), timer = recorder.timer()
        timer.pressed()
        timer.began("w1")
        timer.drew(Self.sections("w0", "w1"), in: nil)
        #expect(recorder.points == [.begin(1, .press)])
        recorder.commit()
        #expect(recorder.points == [.begin(1, .press), .end(1, .drawn)])
        // A later draw of the same row ends nothing again.
        timer.drew(Self.sections("w1"), in: nil)
        recorder.commit()
        #expect(recorder.ends.count == 1)
    }

    @Test func aCreateWithNoPressBeginsAtTheCreate() {
        let recorder = Recorder(), timer = recorder.timer()
        timer.began("w1")
        #expect(recorder.points == [.begin(1, .create)])
        timer.drew(Self.sections("w1"), in: nil)
        recorder.commit()
        #expect(recorder.ends == [.end(1, .drawn)])
    }

    @Test func twoPressesInOneTurnPairWithTheirCreatesInOrder() {
        let recorder = Recorder(), timer = recorder.timer()
        timer.pressed()
        timer.pressed()
        timer.began("a")
        timer.began("b")
        timer.drew(Self.sections("b"), in: nil)
        timer.drew(Self.sections("a", "b"), in: nil)
        recorder.commit()
        #expect(recorder.ends == [.end(2, .drawn), .end(1, .drawn)])
    }

    @Test func aPressWithNoCreateEndsWithNoRowAtItsTurnsCommit() {
        let recorder = Recorder(), timer = recorder.timer()
        timer.pressed()
        recorder.commit()
        #expect(recorder.points == [.begin(1, .press), .end(1, .noRow)])
        // The next create is not paired with that press.
        timer.began("w1")
        #expect(recorder.points.last == .begin(2, .create))
    }

    @Test func aRemovedCreateEndsOnceAndItsRowNeverEndsIt() {
        let recorder = Recorder(), timer = recorder.timer()
        timer.pressed()
        timer.began("w1")
        timer.removed("w1")
        timer.removed("w1")
        timer.drew(Self.sections("w1"), in: nil)
        recorder.commit()
        #expect(recorder.ends == [.end(1, .removed)])
    }

    @Test func aMissedCommitEndsMissed() {
        let recorder = Recorder(), timer = recorder.timer()
        timer.began("w1")
        timer.drew(Self.sections("w1"), in: nil)
        recorder.commit(.missed)
        #expect(recorder.ends == [.end(1, .missed)])
    }

    @Test func createsPastTheLimitEndTheOldest() {
        let recorder = Recorder(), timer = recorder.timer()
        for index in 0...SidebarNewRowTimer.openLimit { timer.began("w\(index)") }
        #expect(recorder.ends == [.end(1, .dropped)])
    }

    @Test func withTheCategoryOffNothingIsWrittenOrAskedFor() {
        let recorder = Recorder(), timer = recorder.timer()
        recorder.isEnabled = false
        timer.pressed()
        timer.began("w1")
        timer.drew(Self.sections("w1"), in: nil)
        timer.removed("w1")
        #expect(recorder.points.isEmpty)
        #expect(recorder.boundaries.isEmpty)
    }
}
