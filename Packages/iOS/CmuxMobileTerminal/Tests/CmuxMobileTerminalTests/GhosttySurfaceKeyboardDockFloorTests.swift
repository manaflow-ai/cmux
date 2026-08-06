#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileSupport
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Regression coverage for the field failure where the keyboard rises but the
/// bottom bars (accessory toolbar + composer band) stay seated at the
/// keyboard-down position behind it.
///
/// In a test window UIKit's `keyboardLayoutGuide` never observes a real
/// keyboard, so it stays on its bottom fallback exactly like a guide that
/// missed a live transition around window (re)attachment. Docking correctly
/// here therefore proves the dock does not depend on the guide having seen the
/// keyboard event. Each test injects a notification-center-isolated
/// `MobileKeyboardFrameTracker` (the floor's single data source) through the
/// surface initializer and calls the view's notification handler directly for
/// animation-curve application, mirroring the production wiring where the
/// shared tracker observes the same notifications the view does.
@MainActor
@Suite("Keyboard dock floor", .serialized)
struct GhosttySurfaceKeyboardDockFloorTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    private struct Harness {
        let view: GhosttySurfaceView
        let window: UIWindow
        let center: NotificationCenter
        let tracker: MobileKeyboardFrameTracker
        /// Retained here because the surface only holds it weakly.
        let delegate: Delegate
    }

    private static let windowHeight: CGFloat = 874
    private static let keyboardHeight: CGFloat = 336

    private func makeHarness(attached: Bool = true) throws -> Harness {
        let center = NotificationCenter()
        let tracker = MobileKeyboardFrameTracker(notificationCenter: center)
        let delegate = Delegate()
        let view = GhosttySurfaceView(
            runtime: try GhosttyRuntime.shared(),
            delegate: delegate,
            fontSize: 10,
            keyboardFrameTracker: tracker
        )
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: Self.windowHeight))
        if attached {
            attach(view, to: window)
        }
        return Harness(view: view, window: window, center: center, tracker: tracker, delegate: delegate)
    }

    private func attach(_ view: GhosttySurfaceView, to window: UIWindow) {
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func tearDown(_ harness: Harness) {
        harness.view.prepareForDismantle()
        harness.view.removeFromSuperview()
        harness.window.isHidden = true
    }

    /// The keyboard notification shape UIKit posts, with `duration` omitted so
    /// the transition applies synchronously in tests.
    private func keyboardNotification(coveringBottom overlap: CGFloat) -> Notification {
        Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0,
                    y: Self.windowHeight - overlap,
                    width: 402,
                    height: Self.keyboardHeight
                ),
            ]
        )
    }

    /// Delivers a keyboard transition the way production sees it: the tracker
    /// (registered first) records it, then the view's handler re-applies the
    /// floor on the notification's animation curve.
    private func deliverKeyboardTransition(
        coveringBottom overlap: CGFloat,
        to harness: Harness
    ) {
        let notification = keyboardNotification(coveringBottom: overlap)
        harness.center.post(notification)
        harness.view.handleKeyboardWillChangeFrame(notification)
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()
    }

    private func probeValue(of view: GhosttySurfaceView, key: String) -> CGFloat? {
        let entry = view.composerDockProbeValue
            .split(separator: ";")
            .first { $0.hasPrefix("\(key)=") }
        guard let entry, let value = Double(entry.dropFirst(key.count + 1)) else {
            return nil
        }
        return CGFloat(value)
    }

    /// The accessory toolbar's keyboard-toggle button, found by its stable
    /// accessibility identifier in the surface's subtree.
    private func keyboardToggleButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           button.accessibilityIdentifier == "terminal.inputAccessory.hideKeyboard" {
            return button
        }
        for subview in view.subviews {
            if let found = keyboardToggleButton(in: subview) {
                return found
            }
        }
        return nil
    }

    @Test("keyboard rise docks the bars above it even when the layout guide missed it")
    func barsRideTheKeyboardWhenTheGuideStaysOnItsFallback() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)

        let dockBottom = Self.windowHeight - Self.keyboardHeight
        let composerMaxY = try #require(probeValue(of: harness.view, key: "composerMaxY"))
        let toolbarMaxY = try #require(probeValue(of: harness.view, key: "toolbarMaxY"))
        let modelKeyboardHeight = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        #expect(abs(composerMaxY - dockBottom) <= 1)
        #expect(abs(toolbarMaxY - dockBottom) <= 1)
        #expect(abs(modelKeyboardHeight - Self.keyboardHeight) <= 1)
    }

    @Test("a view attached after the keyboard came up docks from the tracker")
    func lateAttachedViewDocksFromTheTrackedKeyboardFrame() throws {
        let harness = try makeHarness(attached: false)
        defer { tearDown(harness) }

        // The keyboard transition happens while the view is detached — the
        // workspace-switch case. Only the tracker observes it; the view's
        // handler never runs for it.
        harness.center.post(keyboardNotification(coveringBottom: Self.keyboardHeight))
        attach(harness.view, to: harness.window)

        let dockBottom = Self.windowHeight - Self.keyboardHeight
        let composerMaxY = try #require(probeValue(of: harness.view, key: "composerMaxY"))
        let toolbarMaxY = try #require(probeValue(of: harness.view, key: "toolbarMaxY"))
        let modelKeyboardHeight = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        let keyboardUp = try #require(probeValue(of: harness.view, key: "keyboardUp"))
        #expect(abs(composerMaxY - dockBottom) <= 1)
        #expect(abs(toolbarMaxY - dockBottom) <= 1)
        #expect(abs(modelKeyboardHeight - Self.keyboardHeight) <= 1)
        // The visibility bit catches up too: the toggle must read hide-keyboard.
        #expect(keyboardUp == 1)
    }

    @Test("the floor holds the window-correct seat while the surface's own frame breathes")
    func floorStaysWindowCorrectWhenTheSurfaceFrameChanges() throws {
        let harness = try makeHarness(attached: false)
        defer { tearDown(harness) }

        // Attach with the bottom edge respecting a 34pt indicator inset — the
        // shape the host gives the surface while the keyboard is down.
        harness.view.frame = CGRect(x: 0, y: 0, width: 402, height: Self.windowHeight - 34)
        harness.window.addSubview(harness.view)
        harness.window.isHidden = false
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()

        // The keyboard rises while the frame is still short (mid-transition
        // conversion territory: this is where the device build seeded a floor
        // 34pt shy of the settled truth).
        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)

        // Safe-area propagation then extends the surface to the window bottom.
        harness.view.frame = CGRect(x: 0, y: 0, width: 402, height: Self.windowHeight)
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()

        // The bars must already sit at the window-correct keyboard top — the
        // late +34 pop the dogfood recordings showed is exactly this assertion
        // failing at the old view-anchored floor.
        let dockBottom = Self.windowHeight - Self.keyboardHeight
        let composerMaxY = try #require(probeValue(of: harness.view, key: "composerMaxY"))
        #expect(abs(composerMaxY - dockBottom) <= 1)
    }

    @Test("a fresh toolbar is born in the keyboard-down state")
    func freshToolbarShowsTheShowKeyboardToggle() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        let toggle = try #require(keyboardToggleButton(in: harness.view))
        #expect(toggle.accessibilityLabel == "Show Keyboard")
        let keyboardUp = try #require(probeValue(of: harness.view, key: "keyboardUp"))
        #expect(keyboardUp == 0)
    }

    @Test("re-entering after the keyboard dismissed while detached resets the visibility state")
    func reattachAfterDetachedDismissalShowsKeyboardDownState() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        // Keyboard up while the surface is presented.
        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)
        #expect(try #require(probeValue(of: harness.view, key: "keyboardUp")) == 1)

        // Leave the workspace detail: the surface detaches, THEN the keyboard
        // dismisses. Only the tracker observes the dismissal.
        harness.view.removeFromSuperview()
        harness.center.post(keyboardNotification(coveringBottom: 0))

        // Re-enter: the visibility bit, the toggle glyph state, and the dock
        // must all reflect the keyboard-down truth.
        attach(harness.view, to: harness.window)

        let keyboardUp = try #require(probeValue(of: harness.view, key: "keyboardUp"))
        let bottomSafeArea = try #require(probeValue(of: harness.view, key: "bottomSafeArea"))
        let composerMaxY = try #require(probeValue(of: harness.view, key: "composerMaxY"))
        let toggle = try #require(keyboardToggleButton(in: harness.view))
        #expect(keyboardUp == 0)
        #expect(abs(composerMaxY - (Self.windowHeight - bottomSafeArea)) <= 1)
        #expect(toggle.accessibilityLabel == "Show Keyboard")
    }

    @Test("a dismissal transition releases the floor and reseats the bars at the bottom")
    func dismissalReturnsTheBarsToTheBottomFallback() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)
        deliverKeyboardTransition(coveringBottom: 0, to: harness)

        // Released, the dock reseats on the guide's bottom fallback, which
        // clears the simulator device's real bottom safe-area inset.
        let bottomSafeArea = try #require(probeValue(of: harness.view, key: "bottomSafeArea"))
        let composerMaxY = try #require(probeValue(of: harness.view, key: "composerMaxY"))
        let modelKeyboardHeight = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        #expect(abs(composerMaxY - (Self.windowHeight - bottomSafeArea)) <= 1)
        #expect(abs(modelKeyboardHeight) <= 1)
    }
}
#endif
