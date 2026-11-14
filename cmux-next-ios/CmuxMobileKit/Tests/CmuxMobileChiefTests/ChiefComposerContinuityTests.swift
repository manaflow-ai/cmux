#if os(iOS)
import CmuxConversationUI
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileChief

/// The user, 2026-11-10 (iPhone): "when i reopen a chief convo on ios, it takes
/// a second for the prev composer bar input to come back instead of instant",
/// and "keyboard weirdly unfocuses at random times like when i return from
/// background". The draft was put back in `viewDidAppear`, after the push
/// settled; and coming back from the background the Chief screen is rebuilt on
/// a new store (the link reconnects), which dropped the keyboard.
@MainActor
@Suite struct ChiefComposerContinuityTests {
    /// Reopening Chief: the carried text is in the field as the screen starts
    /// to appear, not once the push animation has finished.
    @Test func theDraftIsInTheFieldBeforeTheScreenAppears() throws {
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        session.carryComposerText("Draft kept across visits")
        let conversation = ConversationViewController(store: session.store, options: .chief)
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        defer { window.isHidden = true; session.store.stop() }
        container.loadViewIfNeeded()
        // The push begins: viewWillAppear runs, the animation has not.
        container.beginAppearanceTransition(true, animated: true)
        window.rootViewController = container
        let field = try #require(container.composerTextView)
        #expect(field.text == "Draft kept across visits", "the draft shows as the screen opens")
        container.endAppearanceTransition()
        #expect(field.text == "Draft kept across visits")
    }

    /// Back from the background the link reconnects and Chief's screen is rebuilt
    /// on the new store: the field keeps its text and its keyboard.
    @Test func aScreenRebuiltOnANewStoreKeepsTheTextAndTheKeyboard() throws {
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChiefConversationScreen(session: session) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; session.store.stop() }

        let first = try #require(drain { composer(in: window) })
        first.becomeFirstResponder()
        first.text = "Half a thought"
        first.delegate?.textViewDidChange?(first)
        try #require(first.isFirstResponder, "the test host can focus the field")

        let oldStore = ObjectIdentifier(session.store)
        session.use(ChiefOfflineBackend())
        #expect(ObjectIdentifier(session.store) != oldStore)
        let rebuilt = try #require(drain { composer(in: window).flatMap { $0 === first ? nil : $0 } },
                                   "the screen is rebuilt on the new store")
        _ = drain { rebuilt.isFirstResponder ? true : nil }
        #expect(rebuilt.text == "Half a thought", "the text moved to the rebuilt screen")
        #expect(rebuilt.isFirstResponder, "the rebuilt screen kept the keyboard")
    }

    /// A Chief screen that was never focused gets no keyboard from a rebuild.
    @Test func aRebuildNeverRaisesTheKeyboardUnasked() throws {
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: NavigationStack { ChiefConversationScreen(session: session) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; session.store.stop() }

        let first = try #require(drain { composer(in: window) })
        #expect(!first.isFirstResponder)
        session.use(ChiefOfflineBackend())
        let rebuilt = try #require(drain { composer(in: window).flatMap { $0 === first ? nil : $0 } })
        for _ in 0 ..< 20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(!rebuilt.isFirstResponder, "no keyboard the person did not ask for")
    }

    private func composer(in window: UIWindow) -> UITextView? {
        window.firstSubview { $0.accessibilityIdentifier == "conversation.composer.text" } as? UITextView
    }

    private func drain<T>(until value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let found = value() { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return value()
    }
}
#endif
