import CmuxNextSignposts
import CoreFoundation
import Foundation
import QuartzCore
import Testing

/// What the run-loop callbacks of one test saw, in order.
@MainActor
private final class Log {
    var events: [String] = []
    var outcomes: [CommitBoundary.Outcome] = []
}

@Suite("Signposts", .serialized)
@MainActor
struct SignpostsTests {
    /// Runs one main run-loop turn that polls and exits without waiting: only the exit activity
    /// fires. A mode with no source returns before notifying observers, so a far-future timer
    /// keeps the default mode non-empty for the turn.
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }

    /// Runs one main run-loop turn that really waits: before-waiting fires, the loop sleeps until
    /// a timer 10 ms out wakes it, the timer logs `timer` and stops the loop. The timer is the
    /// wake under test, not a wait for a condition.
    private func waitingTurn(_ log: Log) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.01, 0, 0, 0) { _ in
            // main-proof: the timer is added to the main run loop only (below).
            MainActor.assumeIsolated { log.events.append("timer") }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 5, false)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test("CommitBoundary runs its work once, when the main run-loop turn ends")
    func commitBoundaryRunsOnceAfterTheTurn() {
        let log = Log()
        CommitBoundary().after { log.outcomes.append($0) }
        #expect(log.outcomes.isEmpty)
        pollingTurn()
        #expect(log.outcomes == [.committed])
        pollingTurn()
        #expect(log.outcomes == [.committed])
    }

    @Test("Boundaries asked for in one turn all run at its end, in the order they were asked for")
    func boundariesInOneTurnRunInOrder() {
        let log = Log()
        CommitBoundary().after { _ in log.events.append("1") }
        CommitBoundary().after { _ in log.events.append("2") }
        pollingTurn()
        #expect(log.events == ["1", "2"])
    }

    @Test("In a turn that waits, the boundary runs before the run loop sleeps (before-waiting), not after the wake")
    func boundaryRunsBeforeWaiting() {
        let log = Log()
        CommitBoundary().after { log.outcomes.append($0); log.events.append("boundary") }
        waitingTurn(log)
        #expect(log.events == ["boundary", "timer"])
        #expect(log.outcomes == [.committed])
    }

    @Test("The boundary runs after an observer at Core Animation's commit order 2,000,000, even one added later")
    func boundaryRunsAfterTheCommitOrder() {
        let log = Log()
        CommitBoundary().after { _ in log.events.append("boundary") }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let commit = CFRunLoopObserverCreateWithHandler(nil, activities, false, 2_000_000) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { log.events.append("commit") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commit, .commonModes)
        pollingTurn()
        CFRunLoopObserverInvalidate(commit)
        #expect(log.events == ["commit", "boundary"])
    }

    @Test("A boundary asked for during a before-waiting callout reports a missed commit at the wake")
    func boundaryAskedForInsideTheCommitPassIsMissed() {
        let log = Log()
        let inPass = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 1_000) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated {
                CommitBoundary().after { log.outcomes.append($0); log.events.append("boundary") }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), inPass, .commonModes)
        waitingTurn(log)
        CFRunLoopObserverInvalidate(inPass)
        #expect(log.events == ["boundary", "timer"])
        #expect(log.outcomes == [.missed])
    }

    /// The boundary is only correct while Core Animation commits at an order below
    /// `CommitBoundary.order`; this reads the main run loop's observers on the macOS that runs it
    /// (14, 15, 26 and 27 are supported), so a change in a new major fails here. AppKit's own
    /// display observers are checked by `CommitBoundaryAppKitTests` (CmuxNextAppTests) and in the
    /// running app by `debug.commit_boundary`.
    @Test("Core Animation's commit observer on this macOS runs before the boundary")
    func coreAnimationCommitsBeforeTheBoundary() throws {
        // A property change on the main thread opens an implicit transaction, which installs
        // Core Animation's commit observer on the main run loop.
        let layer = CALayer()
        layer.opacity = 0.5
        let audit = CommitBoundaryAudit.mainRunLoop()
        pollingTurn()
        try #require(!audit.coreAnimation.isEmpty, "no Core Animation commit observer on the main run loop: \(audit.observers)")
        #expect(audit.late.isEmpty, "observers after the boundary: \(audit.late)")
    }

    @Test("The audit reads every observer from a run loop dump, once each, and flags the late ones")
    func auditReadsADump() {
        let dump = """
        observers = (
            "<CFRunLoopObserver 0x1 [0x2]>{valid = Yes, activities = 0xa0, repeats = Yes, order = 2000000, callout = _ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv (0x3), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x4 [0x2]>{valid = Yes, activities = 0xa0, repeats = Yes, order = 2000000, callout = _ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv (0x3), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x5 [0x2]>{valid = Yes, activities = 0xa0, repeats = Yes, order = 2001000, callout = _NSDisplayCycleObserverCallback (0x6), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x7 [0x2]>{valid = Yes, activities = 0x2, repeats = Yes, order = 2500000, callout = _NSLayoutTimingObserver (0x8), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x9 [0x2]>{valid = Yes, activities = 0x1, repeats = Yes, order = -2147483647, callout = _runLoopObserverCallout (0xa), context = <CFRunLoopObserver context 0x0>}",
        )
        """
        let audit = CommitBoundaryAudit(description: dump)
        #expect(audit.observers.map(\.order) == [-2_147_483_647, 2_000_000, 2_001_000, 2_500_000], "\(audit.observers)")
        #expect(audit.coreAnimation.map(\.activities) == [0xa0])
        // The display cycle observer after the boundary, at before-waiting, makes action.commit end
        // too early; the layout one fires only before timers, where the boundary never does.
        #expect(audit.late.map(\.callout) == ["_NSDisplayCycleObserverCallback"])
    }

    @Test("A late observer counts by its order and activities, whatever its callout's name")
    func aLateBlockObserverIsLate() {
        // CFCopyDescription prints a block observer (CFRunLoopObserverCreateWithHandler: SwiftUI's
        // update cycle, an AppKit observer on a later major) as a trampoline, not a display symbol.
        let dump = """
        observers = (
            "<CFRunLoopObserver 0x1 [0x2]>{valid = Yes, activities = 0xa0, repeats = Yes, order = 2000000, callout = _ZN2CA11Transaction17observer_callbackEP19__CFRunLoopObservermPv (0x3), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x4 [0x2]>{valid = Yes, activities = 0xa0, repeats = No, order = 2000001, callout = __CFRunLoopObserverCreateWithHandler_block_invoke (0x5), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x6 [0x2]>{valid = Yes, activities = 0x20, repeats = Yes, order = 2100000, callout = __CFRunLoopObserverCreateWithHandler_block_invoke (0x5), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x7 [0x2]>{valid = Yes, activities = 0xa0, repeats = Yes, order = 2200000, callout = ??? (0x8), context = <CFRunLoopObserver context 0x0>}",
            "<CFRunLoopObserver 0x9 [0x2]>{valid = Yes, activities = 0xa0, repeats = Yes, order = 2147483647, callout = _wrapRunLoopWithAutoreleasePoolHandler (0xa), context = <CFArray 0xb [0x2]>{type = mutable-small, count = 1, values = (\n\t0 : <0x0>\n)}}",
        )
        """
        let audit = CommitBoundaryAudit(description: dump)
        // Late: the trampoline at 2,100,000 (before waiting) and the unnamed one at 2,200,000. Not
        // late: Core Animation's commit, the boundary's own observer (its order) and the autorelease
        // pool pop at INT_MAX.
        #expect(audit.late.map(\.order) == [2_100_000, 2_200_000], "\(audit.late)")
        #expect(audit.late.allSatisfy { String(describing: $0).contains("valid = Yes") }, "a late observer prints its full dump text")
    }

    @Test("An interval runs its body and returns its value, with a text or an action message")
    func intervalReturnsTheBodyValue() throws {
        let value = Signposter.action.interval(.actionPerform, "id=test") { 42 }
        #expect(value == 42)
        let message = ActionSignpostMessage(id: "test", origin: "cli", inputAgeMilliseconds: -1)
        #expect(Signposter.action.interval(.actionPerform, message) { "ran" } == "ran")
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try Signposter.action.interval(.actionPerform) { throw Failure() }
        }
    }

    @Test("Every catalog name is <category>.<what> of a real category", arguments: SignpostName.allCases)
    func namesCarryTheirCategory(_ name: SignpostName) throws {
        let category = try #require(name.category, "\(name) names no category")
        #expect(name.description.hasPrefix(category.rawValue + "."))
        #expect(name.description.count > category.rawValue.count + 1)
    }

    @Test("No two catalog names record the same string")
    func namesAreUnique() {
        let names = SignpostName.allCases.map(\.description)
        #expect(Set(names).count == names.count, "\(names)")
    }
}
