import AppKit
@testable import CmuxNextApp
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

    /// The PID answers come back as budgeted main posts, which need not keep the order the
    /// activations came in: the newest activation's answer can land first, and the older one that lands after
    /// it is dropped by its sequence.
    @Test func anOlderResolutionThatLandsLastIsDropped() {
        let host = Host()
        let first = NSRunningApplication.current
        let second = NSRunningApplication.current
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: nil)
        let firstSequence = guardian.beginOtherAppActivation()
        let secondSequence = guardian.beginOtherAppActivation()

        guardian.otherAppActivated(second, processIdentifier: 22, sequence: secondSequence)
        guardian.otherAppActivated(first, processIdentifier: 11, sequence: firstSequence)
        guardian.start()

        #expect(host.handedBackTo === second)
        #expect(guardian.giveBacks.last?.restoredTo == 22)
    }
}
