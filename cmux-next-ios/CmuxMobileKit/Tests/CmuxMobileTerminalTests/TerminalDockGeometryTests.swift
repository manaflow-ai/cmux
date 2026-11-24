#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileSupport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-17: "The reconnect takes an extra line and the freaking built
/// in keyboard accounting is there when I'm loading back in even when there's
/// no keyboard!"
///
/// - The dock's guide (the key row and composer hang from it) puts no
///   keyboard inset under the dock when no keyboard can be on screen: a
///   keyboard on record whose hide UIKit never posted (it went while the app
///   was in the background) is dropped when the app is active again.
/// - A reattach past the quiet bound changes no height by the composer: the
///   state is the title pill's subtitle, Reconnect is in the page menu.
@MainActor
@Suite(.serialized) struct TerminalDockGeometryTests {
    /// A window, a view and a dock riding `tracker`, as TerminalViewController hangs its stack.
    @MainActor
    private final class Rig {
        let window: UIWindow
        let view: UIView
        let dock: MobileKeyboardDock

        init(tracker: MobileKeyboardFrameTracker) {
            let controller = UIViewController()
            window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            view = controller.view
            dock = MobileKeyboardDock(view: view, usesBottomSafeArea: false, keyboard: tracker)
            view.layoutIfNeeded()
        }

        /// The keyboard inset under the dock: the view's bottom minus the guide's top.
        var inset: CGFloat {
            dock.refresh()
            view.layoutIfNeeded()
            return view.bounds.maxY - dock.guide.layoutFrame.minY
        }

        func close() {
            window.isHidden = true
        }
    }

    /// The tracker's owner check, and the drops its host heard.
    @MainActor
    private final class Owner {
        var present = true
        var drops = 0
    }

    private static func post(_ center: NotificationCenter, _ frame: CGRect) {
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            center.post(name: name, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: frame,
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            ])
        }
    }

    private static var keyboard: (shown: CGRect, hidden: CGRect) {
        let screen = UIScreen.main.bounds
        return (CGRect(x: 0, y: screen.maxY - 336, width: screen.width, height: 336),
                CGRect(x: 0, y: screen.maxY, width: screen.width, height: 336))
    }

    /// The keyboard was up when the app left; it went while the app was away
    /// and UIKit posted no hide. Back in the foreground with no first
    /// responder that takes text, the dock has no inset (before: 336 pt).
    @Test func aKeyboardNothingOwnsLeavesNoInsetWhenTheAppIsBack() {
        let center = NotificationCenter()
        let owner = Owner()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        tracker.keyboardOwnerPresent = { owner.present }
        let rig = Rig(tracker: tracker)
        defer { rig.close() }
        tracker.subscribeToDrops(rig) { owner.drops += 1 }
        #expect(rig.inset == 0, "no keyboard on load: no inset")

        Self.post(center, Self.keyboard.shown)
        #expect(abs(rig.inset - 336) < 0.5, "keyboard up: the dock rides it")

        // The app goes to the background; the keyboard goes with no notification.
        owner.present = false
        tracker.dropKeyboardWithoutOwner()
        #expect(rig.inset == 0, "back with no keyboard: no keyboard inset")
        #expect(!tracker.isShown)
        #expect(owner.drops == 1, "the host hears the drop (its key row glyph and TUI rows follow)")

        // The next real show still rides the keyboard.
        owner.present = true
        Self.post(center, Self.keyboard.shown)
        #expect(abs(rig.inset - 336) < 0.5)
        Self.post(center, Self.keyboard.hidden)
        #expect(rig.inset == 0, "a real hide: no inset")
    }

    /// The keyboard came back with the app (its first responder stayed): the
    /// record stands and the dock keeps riding it.
    @Test func aKeyboardTheAppStillOwnsStays() {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        tracker.keyboardOwnerPresent = { true }
        let rig = Rig(tracker: tracker)
        defer { rig.close() }
        Self.post(center, Self.keyboard.shown)
        tracker.dropKeyboardWithoutOwner()
        #expect(abs(rig.inset - 336) < 0.5)
        #expect(!tracker.dropKeyboardWithoutOwner())
    }

    /// The real owner lookup: a focused text view owns a keyboard, nothing
    /// focused owns none, a focused view that takes no text owns none. (The
    /// test window has no scene, so it is searched by name; the app's
    /// windows are its scenes'.)
    @Test func theOwnerIsTheFirstResponderThatTakesText() {
        let rig = Rig(tracker: MobileKeyboardFrameTracker(notificationCenter: NotificationCenter()))
        defer { rig.close() }
        let field = UITextView(frame: CGRect(x: 0, y: 100, width: 200, height: 40))
        rig.view.addSubview(field)
        #expect(!MobileKeyboardOwner.isPresent(in: [rig.window]))
        #expect(field.becomeFirstResponder())
        #expect(MobileKeyboardOwner.firstResponder(in: [rig.window]) === field)
        #expect(MobileKeyboardOwner.isPresent(in: [rig.window]))
        _ = field.resignFirstResponder()
        #expect(!MobileKeyboardOwner.isPresent(in: [rig.window]))
        #expect(!MobileKeyboardOwner.takesText(UIView()))
    }

    // MARK: Reattach

    @MainActor
    final class Silent: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        var connectionState: TerminalConnectionState = .attached
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    /// The composer row's height as laid out at a phone's width.
    private static func composerHeight(_ model: TerminalModel) -> CGFloat {
        let host = UIHostingController(rootView: TerminalComposer(model: model).fixedSize(horizontal: false, vertical: true))
        return host.sizeThatFits(in: CGSize(width: 402, height: 2_000)).height
    }

    /// Past the quiet bound of a reattach, the composer is the height it is
    /// attached (before: a footnote row, "Reconnecting to Demo Mac… · Retry").
    /// Nothing on the page says the state at any age (no chip, no pill subtitle:
    /// Leo, 2026-11-24); Reconnect is in the page menu past the quiet bound.
    @Test func aReattachTakesNoRowByTheComposer() {
        let model = TerminalModel(session: Silent(), artifactSource: UnavailableArtifactSource(), title: "zsh",
                                  quietStatus: QuietStatusGate(delay: .zero))
        model.reconnect = {}
        let attached = Self.composerHeight(model)
        #expect(attached > 0)
        #expect(!model.offersReconnect, "attached: no Reconnect")

        model.ingest(.connection(.reattaching(mac: "Demo Mac")))
        #expect(model.connectionLine == "Reconnecting to Demo Mac…", "past the quiet bound")
        #expect(model.offersReconnect, "Reconnect is offered (in the page menu)")
        #expect(Self.composerHeight(model) == attached, "a reattach adds no row by the composer")

        model.ingest(.connection(.failed(message: "daemon channel closed")))
        #expect(Self.composerHeight(model) == attached)

        model.ingest(.connection(.attached))
        #expect(!model.offersReconnect)
    }
}
#endif
