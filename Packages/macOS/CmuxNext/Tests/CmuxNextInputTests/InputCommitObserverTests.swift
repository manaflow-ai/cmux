import CoreFoundation
@testable import CmuxNextInput
import CmuxNextSignposts
import Testing

/// InputCommitObserver: the tracker's commit boundary fires once per arm, after the commit pass that
/// began after the arm, as ``CommitBoundary`` does, with no new observer per turn.
@MainActor
@Suite(.serialized) struct InputCommitObserverTests {
    static let mode = CFRunLoopMode("InputCommitObserverTests.private" as CFString)

    @MainActor
    final class Fired {
        var outcomes: [CommitBoundary.Outcome] = []
        var observer: InputCommitObserver?
        /// Arms again from the handler on its first call.
        var rearmsOnce = false
    }

    private func makeObserver(_ fired: Fired) -> InputCommitObserver {
        let observer = InputCommitObserver(mode: Self.mode)
        fired.observer = observer
        observer.start { [weak fired] outcome in
            guard let fired else { return }
            fired.outcomes.append(outcome)
            if fired.rearmsOnce {
                fired.rearmsOnce = false
                fired.observer?.arm()
            }
        }
        return observer
    }

    @Test("An arm before the turn's commit pass fires once, at that pass's commit")
    func firesAtTheTurnsCommit() {
        let fired = Fired()
        let observer = makeObserver(fired)
        observer.woke()
        observer.arm()
        observer.arm()
        observer.commitPassBegan()
        observer.observed(.beforeWaiting)
        #expect(fired.outcomes == [.committed])
        observer.woke()
        observer.observed(.afterWaiting)
        observer.commitPassBegan()
        observer.observed(.beforeWaiting)
        #expect(fired.outcomes == [.committed], "one call per arm")
    }

    @Test("An arm inside a commit pass misses that pass's commit: missed after a sleep, else the next pass")
    func armInsideACommitPass() {
        let fired = Fired()
        let observer = makeObserver(fired)
        observer.woke()
        observer.commitPassBegan()
        observer.arm()
        observer.observed(.beforeWaiting)
        #expect(fired.outcomes.isEmpty, "the commit of the pass it was armed in is not its own")
        observer.woke()
        observer.observed(.afterWaiting)
        #expect(fired.outcomes == [.missed])

        // A nested loop's exit: no sleep between the passes.
        observer.commitPassBegan()
        observer.arm()
        observer.observed(.beforeWaiting)
        observer.commitPassBegan()
        observer.observed(.exit)
        #expect(fired.outcomes == [.missed, .committed])
    }

    @Test("An arm from the handler fires at the next turn's commit, not again in the same pass")
    func armFromTheHandler() {
        let fired = Fired()
        fired.rearmsOnce = true
        let observer = makeObserver(fired)
        observer.woke()
        observer.arm()
        observer.commitPassBegan()
        observer.observed(.beforeWaiting)
        #expect(fired.outcomes == [.committed])
        observer.woke()
        observer.observed(.afterWaiting)
        #expect(fired.outcomes == [.committed, .missed], "re-armed in the commit pass, then the run loop slept")
    }

    @Test("On a real main run-loop turn the armed boundary fires once after the turn's commit pass")
    func realRunLoopTurn() {
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, Self.mode)
        defer { CFRunLoopTimerInvalidate(keepAlive) }
        let fired = Fired()
        let observer = makeObserver(fired)
        observer.arm()
        _ = CFRunLoopRunInMode(Self.mode, 0, false)
        #expect(fired.outcomes == [.committed])
        _ = CFRunLoopRunInMode(Self.mode, 0, false)
        #expect(fired.outcomes == [.committed], "not armed again")
        observer.arm()
        _ = CFRunLoopRunInMode(Self.mode, 0, false)
        #expect(fired.outcomes == [.committed, .committed], "an arm after a pass fires at the next one")
    }
}
