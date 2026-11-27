#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-25, on swipe back: the composer area showed odd zones and the page did not
/// move as one (paraphrased). The terminal's dock holds where the page drew it while a swipe
/// back, a cancelled swipe or Back runs, and lets go when that transition ends.
///
/// #56696 review (F2): a coordinator that declines `animate(alongsideTransition:)` never calls
/// back, so the dock must not be held for it; else it stays pinned and every later keyboard note
/// is held, through the next transition too.
@MainActor
@Suite(.serialized) struct TerminalNavigationHoldTests {
    @MainActor
    final class Silent: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        var connectionState: TerminalConnectionState = .connecting(mac: "Mac Studio")
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    /// A stand-in coordinator: accepts or declines, and keeps the end it was given.
    @MainActor
    final class FakeTransition {
        var accepts: Bool
        var registrations = 0
        var end: ((Bool) -> Void)?
        init(accepts: Bool) { self.accepts = accepts }
        func register(_ done: @escaping (Bool) -> Void) -> Bool {
            registrations += 1
            guard accepts else { return false }
            end = done
            return true
        }
    }

    static func screen() -> (TerminalViewController, UIWindow) {
        let model = TerminalModel(session: Silent(), artifactSource: UnavailableArtifactSource(), title: "hold")
        let screen = TerminalViewController(model: model, chrome: .embedded)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        screen.view.layoutIfNeeded()
        return (screen, window)
    }

    static func use(_ transition: FakeTransition?, on screen: TerminalViewController) {
        screen.navigationTransition = { transition.map { t in { done in t.register(done) } } }
    }

    @Test func anAcceptedTransitionHoldsTheDockUntilItEnds() {
        let (screen, window) = Self.screen()
        defer { window.isHidden = true }
        let transition = FakeTransition(accepts: true)
        Self.use(transition, on: screen)
        screen.viewWillDisappear(true)
        #expect(screen.holdsDockForNavigation)
        // Keyboard notes during it are held, not registered again.
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(transition.registrations == 1)
        transition.end?(false)
        #expect(!screen.holdsDockForNavigation)
    }

    @Test func aCancelledSwipeLetsTheDockGo() {
        let (screen, window) = Self.screen()
        defer { window.isHidden = true }
        let transition = FakeTransition(accepts: true)
        Self.use(transition, on: screen)
        screen.viewWillDisappear(true)
        #expect(screen.holdsDockForNavigation)
        transition.end?(true)
        #expect(!screen.holdsDockForNavigation)
    }

    @Test func aDeclinedTransitionHoldsNothingAndTheNextIsHeld() {
        let (screen, window) = Self.screen()
        defer { window.isHidden = true }
        let declined = FakeTransition(accepts: false)
        Self.use(declined, on: screen)
        screen.viewWillDisappear(true)
        #expect(declined.registrations == 1)
        #expect(!screen.holdsDockForNavigation)
        // Its keyboard notes are not swallowed into a hold nothing ends: each asks again.
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(declined.registrations == 2)
        #expect(!screen.holdsDockForNavigation)

        // The next transition, say a Back, is followed and ends the hold.
        let next = FakeTransition(accepts: true)
        Self.use(next, on: screen)
        screen.viewWillDisappear(true)
        #expect(next.registrations == 1)
        #expect(screen.holdsDockForNavigation)
        next.end?(false)
        #expect(!screen.holdsDockForNavigation)
    }

    @Test func noTransitionHoldsNothing() {
        let (screen, window) = Self.screen()
        defer { window.isHidden = true }
        Self.use(nil, on: screen)
        screen.viewWillDisappear(false)
        #expect(!screen.holdsDockForNavigation)
    }
}
#endif
