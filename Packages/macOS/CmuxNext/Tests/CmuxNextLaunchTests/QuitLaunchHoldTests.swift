import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A quit's hold on the launch (p08-startup task 105), the steps `QuitCoordinator` runs: `shouldTerminate` holds
/// startup while the quit decides, a decided quit (`complete`) ends the launch's scheduler, and both cancel paths
/// (an unsaved document kept, the dialog's Cancel: `cancelQuit`) release the hold with `quitCancelled`.
@MainActor
struct QuitLaunchHoldTests {
    /// A quit before the launch completed: no afterStartup task runs, and the launch never completes.
    @Test func aDecidedQuitBeforeCompletionRunsNoAfterStartupTask() {
        let s = StartupTestScheduler()
        let ran = QuitLaunchFlag(), completed = QuitLaunchFlag()
        s.startup.post(.afterStartup, "Palette.prepare", on: .main) { ran.isSet = true }
        s.startup.whenComplete { _ in completed.isSet = true }
        let hold = QuitLaunchHold(startup: s.startup)
        hold.deciding()
        s.complete()
        #expect(s.startup.heldRefs == ["Quit.deciding"], "a deciding quit holds startup")
        #expect(s.startup.completion == nil)
        hold.decided()
        #expect(!hold.isHolding)
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(!ran.isSet)
        #expect(!completed.isSet)
        #expect(s.startup.completion == nil)
        #expect(s.startup.log.phase == .quitting)
    }

    /// A cancelled quit (either cancel path) releases its hold: the launch completes with `quitCancelled`, and its
    /// afterStartup tasks run.
    @Test func aCancelledQuitReleasesItsHoldAndTheLaunchCompletes() {
        let s = StartupTestScheduler()
        let ran = QuitLaunchFlag()
        s.startup.post(.afterStartup, "Palette.prepare", on: .main) { ran.isSet = true }
        let hold = QuitLaunchHold(startup: s.startup)
        hold.deciding()
        s.complete()
        #expect(s.startup.heldRefs == ["Quit.deciding"])
        hold.cancelled()
        #expect(!hold.isHolding)
        #expect(!s.startup.heldRefs.contains("Quit.deciding"))
        s.hand.drain()
        #expect(s.startup.completion?.reason == .quitCancelled)
        s.fire()
        #expect(ran.isSet)
    }

    /// A quit after the launch completed holds nothing and changes no completion.
    @Test func aQuitAfterCompletionHoldsNothing() {
        let s = StartupTestScheduler()
        s.complete()
        let reason = s.startup.completion?.reason
        #expect(reason != nil)
        let hold = QuitLaunchHold(startup: s.startup)
        hold.deciding()
        #expect(!hold.isHolding)
        #expect(s.startup.heldRefs.isEmpty)
        hold.cancelled()
        #expect(s.startup.completion?.reason == reason)
    }

    /// With no launch scheduler (a test's services) each step does nothing.
    @Test func noLaunchSchedulerIsANoOp() {
        let hold = QuitLaunchHold(startup: nil)
        hold.deciding()
        #expect(!hold.isHolding)
        hold.cancelled()
        hold.decided()
        #expect(!hold.isHolding)
    }
}

/// Set by a main-actor task or callback.
@MainActor
private final class QuitLaunchFlag {
    var isSet = false
}
