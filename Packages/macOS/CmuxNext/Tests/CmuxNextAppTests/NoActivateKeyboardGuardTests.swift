import AppKit
@testable import CmuxNextFocusUI
import Testing

@MainActor @Suite(.serialized)
struct NoActivateKeyboardGuardTests {
    private final class Host: NoActivateKeyboardGuard.Host {
        var mouseButtonDown = false
        var commandHeld = false
        var isAppActive = true
        var now: ContinuousClock.Instant = .now
        var handedBackTo: NSRunningApplication?
        var scheduled: [(delay: Duration, body: @MainActor @Sendable () -> Void)] = []

        func giveActivationBack(to app: NSRunningApplication?) {
            handedBackTo = app
        }

        func schedule(after delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void) {
            scheduled.append((delay, body))
        }

        /// Lets the waits run out: time passes, then every scheduled deadline fires.
        func elapse(_ duration: Duration) {
            now = now + duration
            let due = scheduled
            scheduled.removeAll()
            for entry in due { entry.body() }
        }
    }

    @Test func giveBackUsesTheAlreadyResolvedApplicationAndPid() {
        let host = Host()
        let application = NSRunningApplication.current
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: application, frontmostPID: 4242)

        guardian.start()

        #expect(host.handedBackTo === application)
        #expect(guardian.giveBacks == [
            .init(trigger: .appActivated, cause: "no_user_input", restoredTo: 4242),
        ])
    }

    @Test func laterActivationReplacesTheResolvedTargetWithoutLookup() {
        let host = Host()
        let first = NSRunningApplication.current
        let second = NSRunningApplication.current
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: first, frontmostPID: 11)

        guardian.otherAppActivated(second, processIdentifier: 22)
        guardian.start()

        #expect(host.handedBackTo === second)
        #expect(guardian.giveBacks.last?.restoredTo == 22)
    }

    @Test func anOlderBackgroundResolutionCannotReplaceTheNewestActivation() {
        let host = Host()
        let first = NSRunningApplication.current
        let second = NSRunningApplication.current
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: nil)
        let firstSequence = guardian.beginOtherAppActivation()
        let secondSequence = guardian.beginOtherAppActivation()

        guardian.otherAppActivated(first, processIdentifier: 11, sequence: firstSequence)
        guardian.otherAppActivated(second, processIdentifier: 22, sequence: secondSequence)
        guardian.start()

        #expect(host.handedBackTo === second)
        #expect(guardian.giveBacks.last?.restoredTo == 22)
    }

    /// An update relaunch's startup: a click or Cmd-Tab that activated the app is the user
    /// choosing it (the startup ends), and a stopped guard gives nothing back.
    @Test func anActivationWithIntentReportsTheUserChoseAndAStoppedGuardStepsAside() {
        let host = Host()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        var chose = 0
        guardian.onUserChose = { chose += 1 }
        host.commandHeld = true
        guardian.appDidBecomeActive()
        #expect(chose == 1)
        #expect(host.handedBackTo == nil)

        host.commandHeld = false
        guardian.isEnabled = false
        guardian.appDidBecomeActive()
        guardian.windowDidBecomeKey()
        #expect(host.handedBackTo == nil)
        #expect(guardian.giveBacks.isEmpty)
    }

    /// LaunchServices activates an update relaunch at launch while the user may hold Command or a
    /// mouse button in their own app: that is not intent, so the front goes back.
    @Test func heldInputRightAfterAnUpdateRelaunchIsNotIntent() {
        let host = Host()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        var chose = 0
        guardian.onUserChose = { chose += 1 }
        guardian.ignoresHeldInputUntil = host.now + NoActivateKeyboardGuard.launchActivationGrace
        host.commandHeld = true
        guardian.start()
        #expect(chose == 0)
        #expect(guardian.giveBacks.count == 1)

        guardian.appDidResignActive()
        host.now = host.now + .seconds(3)
        guardian.appDidBecomeActive()
        #expect(chose == 1, "Cmd-Tab after the launch is the user's")
    }

    /// https://github.com/manaflow-ai/cmux/issues/34575: an agent-launched build (CMUX_NEXT_NO_ACTIVATE=1)
    /// that the person clicks. macOS activates the app (and makes its window key) before the click's
    /// mouse-down reaches it, after a quick click was already released: the front stays once the
    /// mouse-down arrives within the wait, instead of going back to the app the person came from.
    @Test func aClickWhoseMouseDownArrivesAfterTheActivationKeepsTheFront() {
        let host = Host()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        guardian.appDidBecomeActive()
        guardian.windowDidBecomeKey()
        #expect(host.handedBackTo == nil, "nothing goes back before the click's input had its chance")
        #expect(host.scheduled.count == 1, "one wait for the activation's two notifications")
        #expect(host.scheduled.first?.delay == NoActivateKeyboardGuard.intentArrivalWindow)

        guardian.userInput()
        host.elapse(NoActivateKeyboardGuard.intentArrivalWindow)
        #expect(host.handedBackTo == nil)
        #expect(guardian.giveBacks.isEmpty)
    }

    /// A Dock click or the Tag Opener opening the running build reaches the app as a reopen, around
    /// its activation: before it or after it, the activation stays.
    @Test func aReopenAroundTheActivationKeepsTheFront() {
        let host = Host()
        let after = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        after.appDidBecomeActive()
        after.reopenRequested()
        host.elapse(NoActivateKeyboardGuard.intentArrivalWindow)
        #expect(after.giveBacks.isEmpty)

        let before = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        before.reopenRequested()
        before.appDidBecomeActive()
        #expect(host.scheduled.isEmpty, "a reopen just before is intent at once")
        #expect(before.giveBacks.isEmpty)
        #expect(host.handedBackTo == nil)
    }

    /// A key typed while an activation waits belongs to the app the person is in: it neither ends
    /// the wait nor keeps the front once the wait runs out. A key typed in cmux just before is intent.
    @Test func aKeyTypedDuringTheWaitIsNotIntent() {
        let host = Host()
        let previous = NSRunningApplication.current
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: previous, frontmostPID: 7)
        guardian.appDidBecomeActive()
        host.now = host.now + .milliseconds(50)
        guardian.userInput(pointer: false)
        #expect(host.scheduled.count == 1, "the key does not end the wait")
        host.elapse(NoActivateKeyboardGuard.intentArrivalWindow)
        #expect(host.handedBackTo === previous)
        #expect(guardian.giveBacks.count == 1)

        guardian.appDidResignActive()
        host.handedBackTo = nil
        guardian.userInput(pointer: false)
        guardian.appDidBecomeActive()
        #expect(host.scheduled.isEmpty, "a key just before the activation is intent")
        #expect(host.handedBackTo == nil)
    }

    /// A reopen is intent only around its own activation: one that comes later goes back.
    @Test func anOldReopenIsNotIntent() {
        let host = Host()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        guardian.reopenRequested()
        host.now = host.now + NoActivateKeyboardGuard.intentArrivalWindow + .milliseconds(100)
        guardian.appDidBecomeActive()
        host.elapse(NoActivateKeyboardGuard.intentArrivalWindow)
        #expect(guardian.giveBacks.count == 1)
    }

    /// An activation nothing the person did caused still goes back, once the wait ends, and only once
    /// for its two notifications; a wait whose activation already resigned gives nothing back.
    @Test func anActivationWithNoInputStillGoesBackAfterTheWait() {
        let host = Host()
        let previous = NSRunningApplication.current
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: previous, frontmostPID: 7)
        guardian.appDidBecomeActive()
        guardian.windowDidBecomeKey()
        host.elapse(NoActivateKeyboardGuard.intentArrivalWindow + .seconds(1))
        #expect(host.handedBackTo === previous)
        #expect(guardian.giveBacks == [.init(trigger: .appActivated, cause: "no_user_input", restoredTo: 7)])

        guardian.appDidResignActive()
        host.handedBackTo = nil
        guardian.appDidBecomeActive()
        guardian.appDidResignActive()
        host.elapse(NoActivateKeyboardGuard.intentArrivalWindow)
        #expect(host.handedBackTo == nil)
        #expect(guardian.giveBacks.count == 1)
    }

    /// The launch check never waits, nor does an activation that arrives in the launch's grace
    /// (macOS activating the agent-launched app as it starts): both go back at once.
    @Test func launchActivationsGoBackWithoutWaiting() {
        let host = Host()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 7)
        guardian.start()
        #expect(host.scheduled.isEmpty)
        #expect(guardian.giveBacks.count == 1)

        guardian.appDidResignActive()
        host.now = host.now + .milliseconds(500)
        guardian.appDidBecomeActive()
        #expect(host.scheduled.isEmpty)
        #expect(guardian.giveBacks.count == 2)

        guardian.appDidResignActive()
        host.now = host.now + NoActivateKeyboardGuard.launchActivationGrace
        guardian.appDidBecomeActive()
        #expect(host.scheduled.count == 1, "after the launch an activation waits for its click")
    }
}
