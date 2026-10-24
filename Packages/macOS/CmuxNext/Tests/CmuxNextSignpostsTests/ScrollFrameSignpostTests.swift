@testable import CmuxNextSignposts
import CoreFoundation
import Foundation
import Testing

/// `key.scroll_frame` runs on every scroll event (about 120 a second on a trackpad, plus momentum) for every user,
/// recorder attached or not, so its per-event cost is the signpost calls only: typed fields the log system formats
/// when something reads them (no `String` per event), and one commit boundary per main run-loop turn that closes
/// every interval whose dispatch ended in that turn (one run-loop observer per turn, not one per event).
@MainActor
struct ScrollFrameSignpostTests {
    /// A signpost whose commit boundary the test fires itself.
    final class Harness {
        var boundaries: [@MainActor (CommitBoundary.Outcome) -> Void] = []
        var clock: TimeInterval = 100
        lazy var signpost = ScrollFrameSignpost(
            signposter: Signposter(category: .key, mirror: SignpostMetricKitMirror()),
            afterCommit: { [unowned self] body in boundaries.append(body) },
            now: { [unowned self] in clock })

        /// Fires the boundaries asked for so far, as the turn's commit does.
        func commit(_ outcome: CommitBoundary.Outcome = .committed) {
            let fire = boundaries
            boundaries.removeAll()
            for body in fire { body(outcome) }
        }
    }

    @Test func theAgeIsTheEventsWaitInMillisecondsAndMinusOneWithoutATimestamp() {
        #expect(abs(ScrollFrameSignpost.ageMilliseconds(eventTimestamp: 10, now: 10.0125) - 12.5) < 1e-6)
        #expect(ScrollFrameSignpost.ageMilliseconds(eventTimestamp: 0, now: 10) == -1)
        #expect(ScrollFrameSignpost.ageMilliseconds(eventTimestamp: 11, now: 10) == 0, "a clock skew never gives a negative age")
    }

    @Test func theScrollsOfOneTurnShareOneCommitBoundary() {
        let h = Harness()
        for phase: ScrollFramePhase in [.began, .changed, .changed, .ended] {
            h.signpost.begin(phase: phase, eventTimestamp: 99.99)
            h.signpost.end(target: .layout)
        }
        #expect(h.boundaries.count == 1, "one run-loop observer per turn, not one per scroll event")
        #expect(h.signpost.endedCount == 4)
        h.commit()
        #expect(h.signpost.endedCount == 0, "the turn's commit closes every interval that ended in it")
        #expect(h.signpost.openCount == 0)

        h.signpost.begin(phase: .momentum, eventTimestamp: 100)
        #expect(h.boundaries.isEmpty, "the boundary is asked for when a dispatch ends, not when it begins")
        h.signpost.end(target: .content)
        #expect(h.boundaries.count == 1, "the next turn asks for its own boundary")
        h.commit()
        #expect(h.signpost.endedCount == 0)
    }

    @Test func aMissedCommitClosesTheTurnsIntervalsToo() {
        let h = Harness()
        h.signpost.begin(phase: .changed, eventTimestamp: 99)
        h.signpost.end(target: .layout)
        h.signpost.begin(phase: .changed, eventTimestamp: 99)
        h.signpost.end(target: .content)
        h.commit(.missed)
        #expect(h.signpost.endedCount == 0)
        h.signpost.begin(phase: .changed, eventTimestamp: 99)
        h.signpost.end(target: .layout)
        #expect(h.boundaries.count == 1, "after a missed boundary the next turn asks again")
    }

    @Test func nestedDispatchesEndInnermostFirst() {
        let h = Harness()
        h.signpost.begin(phase: .changed, eventTimestamp: 99)
        h.signpost.begin(phase: .wheel, eventTimestamp: 0)
        #expect(h.signpost.openCount == 2)
        h.signpost.end(target: .content)
        #expect(h.signpost.openCount == 1, "the inner dispatch's end closes the inner timing only")
        #expect(h.signpost.endedCount == 1)
        h.signpost.end(target: .layout)
        #expect(h.signpost.openCount == 0)
        #expect(h.boundaries.count == 1)
        h.commit()
        #expect(h.signpost.endedCount == 0)
    }

    @Test func anEndWithNothingOpenEndsNothing() {
        let h = Harness()
        h.signpost.end(target: .layout)
        #expect(h.signpost.endedCount == 0)
        #expect(h.boundaries.isEmpty)
    }

    @Test func theRealCommitBoundaryClosesTheTurnsIntervalsWhenTheTurnEnds() {
        final class Count { var value = 0 }
        let asked = Count()
        let signpost = ScrollFrameSignpost(
            signposter: Signposter(category: .key, mirror: SignpostMetricKitMirror()),
            afterCommit: { body in asked.value += 1; CommitBoundary().after(body) },
            now: { ProcessInfo.processInfo.systemUptime })
        for _ in 0..<3 {
            signpost.begin(phase: .changed, eventTimestamp: ProcessInfo.processInfo.systemUptime)
            signpost.end(target: .layout)
        }
        #expect(asked.value == 1)
        #expect(signpost.endedCount == 3)
        // One main run-loop turn that polls and exits (the exit activity fires the boundary). A far-future timer
        // keeps the default mode non-empty, since a mode with no source returns before notifying observers.
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
        #expect(signpost.endedCount == 0)
    }

    @Test func theNameIsInTheKeyCategory() {
        #expect(SignpostName.scrollToFrame.description == "key.scroll_frame")
        #expect(SignpostName.scrollToFrame.category == .key)
    }
}
