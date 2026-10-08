import AppKit
import Testing
@testable import CmuxNextApp

/// A no-activate tagged app that macOS activates (or whose window becomes
/// key) without the user gives the keyboard back to the app the user was in.
@MainActor
struct NoActivateKeyboardGuardTests {
    final class FakeHost: NoActivateKeyboardGuard.Host {
        var mouseButtonDown = false
        var commandHeld = false
        var isAppActive = false
        var now = ContinuousClock.now
        var givenBackTo: [pid_t?] = []
        func giveActivationBack(to app: pid_t?) {
            givenBackTo.append(app)
            isAppActive = false
        }
    }

    @Test func aLaunchActivationWithoutInputGivesTheKeyboardBack() {
        let host = FakeHost()
        var journaled: [NoActivateKeyboardGuard.GiveBack] = []
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501, onGiveBack: { journaled.append($0) })
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo == [501])
        #expect(!host.isAppActive)
        #expect(guardian.giveBacks.count == 1)
        #expect(journaled.first?.trigger == .appActivated)
        #expect(journaled.first?.cause == "no_user_input")
        #expect(journaled.first?.restoredTo == 501)
    }

    @Test func theKeyboardGoesBackToTheLastOtherFrontmostApp() {
        let host = FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        guardian.otherAppActivated(777)
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo == [777])
    }

    @Test func aKeyWindowInTheActiveAppWithoutInputGivesItBack() {
        let host = FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        host.isAppActive = true
        guardian.windowDidBecomeKey()
        #expect(host.givenBackTo == [501])
        #expect(guardian.giveBacks.map(\.trigger) == [.windowKey])
    }

    @Test func aClickOnTheWindowKeepsTheActivation() {
        let host = FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        host.mouseButtonDown = true
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo.isEmpty)
        #expect(guardian.giveBacks.isEmpty)
    }

    @Test func commandTabKeepsTheActivation() {
        let host = FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        host.commandHeld = true
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo.isEmpty)
    }

    @Test func recentInputKeepsItAndOldInputDoesNot() {
        let host = FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        guardian.userInput()
        host.now += .milliseconds(300)
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo.isEmpty)
        host.isAppActive = false
        host.now += .seconds(5)
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(host.givenBackTo == [501])
    }
}

extension NoActivateKeyboardGuardTests {
    /// One system activation posts didBecomeKey and didBecomeActive a few
    /// milliseconds apart: that is one give-back, not two. A second
    /// activation later is counted again.
    @Test func keyAndActivationTogetherAreOneGiveBack() {
        let host = FakeHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        host.isAppActive = true
        guardian.windowDidBecomeKey()
        host.isAppActive = true  // macOS still reports active for this batch
        host.now += .milliseconds(30)
        guardian.appDidBecomeActive()
        #expect(guardian.giveBackCount == 1)
        #expect(host.givenBackTo.count == 2, "the second notification still steps aside")
        // The app really resigned; a new activation is counted again.
        guardian.appDidResignActive()
        host.isAppActive = true
        guardian.appDidBecomeActive()
        #expect(guardian.giveBackCount == 2)
    }
}

extension NoActivateKeyboardGuardTests {
    /// macOS can activate the app before the guard observes anything; the
    /// guard checks once when it starts.
    @Test func anActivationBeforeTheGuardStartedIsGivenBackAtStart() {
        let host = FakeHost()
        host.isAppActive = true
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: 501)
        guardian.start()
        #expect(host.givenBackTo == [501])
        #expect(guardian.giveBackCount == 1)
    }
}
