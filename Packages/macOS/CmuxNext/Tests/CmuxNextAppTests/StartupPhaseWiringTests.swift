import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The startup phases wired to the app (p06-scheduler-007): `LaunchReveal`'s last region reveals
/// the launch, and the daemon store's first snapshot, the window restore and the visible page's
/// load-idle settle it, each through its own injected closure (`AppDelegate` wires them).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct StartupPhaseWiringTests {
    @MainActor private final class Count {
        var value = 0
    }

    private static func tree() -> DaemonTree {
        DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [])])
    }

    @Test func theLastLaunchRegionRevealsTheLaunchOnce() {
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let revealed = Count()
        let reveal = LaunchReveal(clock: ManualClock(), deadline: .seconds(60)) {
            revealed.value += 1
            startup.noteFirstFrame()
        }
        var order: [String] = []
        startup.whenReached(.revealed) { order.append("launch.revealed") }
        startup.whenReached(MainWorkClass.background.startupOpening) { order.append("background") }

        reveal.markReady(.sidebar)
        reveal.markReady(.tabs)
        #expect(!reveal.isRevealed)
        #expect(startup.phase == .launching, "a region still held keeps the launch launching")
        #expect(order.isEmpty, "no background work before the reveal")

        reveal.markReady(.pane)
        #expect(reveal.isRevealed)
        #expect(revealed.value == 1)
        #expect(startup.phase == .revealed)
        #expect(startup.revealCause == .firstFrame)
        #expect(order == ["launch.revealed", "background"], "the reveal mark comes before any background task")

        reveal.markAllReady()
        reveal.markReady(.pane)
        #expect(revealed.value == 1, "the reveal callback runs once")
    }

    @Test func theRevealDeadlineCallsOnRevealed() async throws {
        let clock = ManualClock()
        let revealed = Count()
        let reveal = LaunchReveal(clock: clock, deadline: .milliseconds(1_500)) { revealed.value += 1 }
        reveal.hold(NSView(), until: .pane)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_500))
        await withCheckedContinuation { continuation in reveal.whenReady(.pane) { continuation.resume() } }
        #expect(reveal.isRevealed)
        #expect(revealed.value == 1)
    }

    @Test func theFirstSnapshotCallbackRunsOnceForTheLiveTree() {
        let store = DaemonStore()
        let ran = Count()
        store.whenFirstSnapshotApplied { ran.value += 1 }
        store.applyProvisional(snapshot: Self.tree())
        #expect(ran.value == 0, "the launch snapshot is not the live tree")
        store.apply(snapshot: Self.tree())
        #expect(ran.value == 1)
        store.apply(snapshot: Self.tree())
        #expect(ran.value == 1, "later snapshots do not run it again")
        store.whenFirstSnapshotApplied { ran.value += 1 }
        #expect(ran.value == 2, "asked after the first snapshot, it runs at once")
    }

    @Test func noBrowserPageInFrontIsIdleAtOnce() {
        let services = AppServices(environment: AppEnvironment.current([:]), launchReveal: LaunchReveal(deadline: .seconds(60)))
        let idle = Count()
        services.windows.whenVisiblePageIdle { idle.value += 1 }
        #expect(idle.value == 1)
    }
}
