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

        func giveActivationBack(to app: NSRunningApplication?) {
            handedBackTo = app
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
}
