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
