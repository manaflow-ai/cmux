#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileSupport
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Contract coverage for the keyboard dock accessory: the bottom dock (toolbar
/// row + composer band) is one self-sizing `UIInputView` that the OS keyboard
/// system positions. Every cmux keyboard owner returns it as its
/// `inputAccessoryView` — the terminal input proxy while typing (the dock rides
/// the keyboard's own animation) and the surface itself in the keyboard-down
/// state (the system docks it at the screen bottom) — so the surface never
/// computes a dock position. What remains surface-owned is the MODEL: the grid
/// reservation derived from the notification-tracked keyboard overlap.
///
/// A test window never shows a real keyboard, so these tests assert the
/// responder wiring and the model, not OS-owned positions. Each test injects a
/// notification-center-isolated `MobileKeyboardFrameTracker` (the model's
/// single data source) through the surface initializer and calls the view's
/// notification handler directly, mirroring the production wiring where the
/// shared tracker observes the same notifications the view does.
@MainActor
@Suite("Keyboard dock accessory", .serialized)
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
        // Key AND visible: first-responder status (the keyboard-down docking
        // seat under test) requires the view's window to be key.
        window.makeKeyAndVisible()
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
    /// overlap model on the notification's animation curve.
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
    /// accessibility identifier in the given subtree.
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

    private func mountFocusedComposer(in harness: Harness) throws -> UITextField {
        let host = UIView()
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            field.topAnchor.constraint(equalTo: host.topAnchor),
            field.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        harness.view.setComposerActive(true)
        harness.view.mountComposerView(host)
        harness.view.setComposerBandHeight(60, animated: false)
        #expect(field.becomeFirstResponder())
        harness.view.composerInputFocusChanged(true)
        return field
    }

    @Test("the dock accessory exists, hosts toolbar + composer, and is the inputAccessoryView")
    func accessoryHostsToolbarAndComposerBand() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        let accessory = try #require(
            harness.view.inputAccessoryView as? KeyboardDockAccessoryView
        )
        // The toolbar row (identified by its keyboard-toggle button) lives
        // INSIDE the accessory, not in the surface's own subtree.
        #expect(keyboardToggleButton(in: accessory) != nil)
        #expect(keyboardToggleButton(in: harness.view) == nil)
        // The composer band is the accessory's other slot: a host-mounted
        // compose view lands inside the accessory subtree.
        let composerContent = UIView()
        harness.view.mountComposerView(composerContent)
        #expect(composerContent.isDescendant(of: accessory))
        // The typing responder shares the exact same accessory instance, so
        // the dock transfers seamlessly between keyboard owners.
        #expect(harness.view.inputProxyForTesting.inputAccessoryView === accessory)
    }

    @Test("the accessory toolbar and composer share one transparent material backing")
    func accessoryUsesOneMaterialBacking() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        let accessory = try #require(
            harness.view.inputAccessoryView as? KeyboardDockAccessoryView
        )
        let toolbar = try #require(
            accessory.subviews.first { keyboardToggleButton(in: $0) != nil }
        )
        let toolbarBacking = try #require(toolbar.subviews.first)

        #expect(accessory.backgroundColor == .clear)
        #expect(toolbar.backgroundColor == .clear)
        #expect(toolbarBacking.backgroundColor == .clear)
    }

    @Test("composer growth changes the accessory intrinsic height by the same amount")
    func composerGrowthInvalidatesAccessoryIntrinsicHeight() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        let accessory = try #require(
            harness.view.inputAccessoryView as? KeyboardDockAccessoryView
        )
        let before = accessory.intrinsicContentSize.height

        harness.view.setComposerBandHeight(96, animated: false)

        #expect(abs(accessory.intrinsicContentSize.height - before - 96) <= 0.5)
    }

    @Test("hidden chrome withholds the accessory from the keyboard system")
    func chromeHiddenReturnsNilAccessory() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        #expect(harness.view.inputAccessoryView != nil)
        harness.view.setChromeHidden(true)
        #expect(harness.view.inputAccessoryView == nil)
        #expect(harness.view.inputProxyForTesting.inputAccessoryView == nil)
        harness.view.setChromeHidden(false)
        #expect(harness.view.inputAccessoryView != nil)
    }

    @Test("after attach without autofocus the surface holds first responder (docked accessory state)")
    func attachSeatsSurfaceAsFirstResponder() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        // No cmux text responder owns the keyboard and the chrome is visible,
        // so the SURFACE must hold first responder — that is what makes the
        // system dock the accessory at the screen bottom.
        #expect(harness.view.isFirstResponder)
    }

    @Test("a keyboard rise updates the grid overlap model from the tracked window-space overlap")
    func keyboardRiseUpdatesOverlapModel() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)

        // UIKit's frame includes the accessory. The grid reserves the toolbar
        // separately, so the keyboard model contains only the key plane.
        let modelKeyboardHeight = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        let accessory = try #require(
            harness.view.inputAccessoryView as? KeyboardDockAccessoryView
        )
        let expectedKeyPlane = Self.keyboardHeight - accessory.contentHeight
        #expect(abs(modelKeyboardHeight - expectedKeyPlane) <= 1)

        // Dismissal releases the model back to zero.
        deliverKeyboardTransition(coveringBottom: 0, to: harness)
        let released = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        #expect(abs(released) <= 1)
    }

    @Test("a view attached after the keyboard came up seats the model from the tracker")
    func lateAttachedViewSeatsModelFromTracker() throws {
        let harness = try makeHarness(attached: false)
        defer { tearDown(harness) }

        // The keyboard transition happens while the view is detached — the
        // workspace-switch case. Only the tracker observes it; the view's
        // handler never runs for it.
        harness.center.post(keyboardNotification(coveringBottom: Self.keyboardHeight))
        attach(harness.view, to: harness.window)

        let modelKeyboardHeight = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        let keyboardUp = try #require(probeValue(of: harness.view, key: "keyboardUp"))
        let accessory = try #require(
            harness.view.inputAccessoryView as? KeyboardDockAccessoryView
        )
        let expectedKeyPlane = Self.keyboardHeight - accessory.contentHeight
        #expect(abs(modelKeyboardHeight - expectedKeyPlane) <= 1)
        // The visibility bit catches up too: the toggle must read hide-keyboard.
        #expect(keyboardUp == 1)
    }

    @Test("a fresh toolbar is born in the keyboard-down state")
    func freshToolbarShowsTheShowKeyboardToggle() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        let accessory = try #require(harness.view.inputAccessoryView)
        let toggle = try #require(keyboardToggleButton(in: accessory))
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

        // Re-enter: the visibility bit and the toggle glyph must reflect the
        // keyboard-down truth (positions are OS-owned now, so only the state
        // is asserted).
        attach(harness.view, to: harness.window)

        let keyboardUp = try #require(probeValue(of: harness.view, key: "keyboardUp"))
        let accessory = try #require(harness.view.inputAccessoryView)
        let toggle = try #require(keyboardToggleButton(in: accessory))
        #expect(keyboardUp == 0)
        #expect(toggle.accessibilityLabel == "Show Keyboard")
    }

    @Test("rapid hide and show restores the composer field as keyboard owner")
    func rapidKeyboardToggleRestoresComposerOwner() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        let field = try mountFocusedComposer(in: harness)
        let accessory = try #require(harness.view.inputAccessoryView)
        let toggle = try #require(keyboardToggleButton(in: accessory))
        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)

        toggle.sendActions(for: .touchUpInside)
        #expect(harness.view.isFirstResponder)
        #expect(!field.isFirstResponder)

        // The second tap lands before a keyboard-down notification. It must
        // invert the previous request and restore the field that owned typing,
        // not send subsequent text to the hidden terminal proxy.
        toggle.sendActions(for: .touchUpInside)
        #expect(field.isFirstResponder)
        #expect(!harness.view.inputProxyForTesting.isFirstResponder)
    }

    @Test("the keyboard toggle glyph follows rapid requested state immediately")
    func rapidKeyboardToggleUpdatesGlyphOptimistically() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        harness.view.focusInput()
        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)
        let accessory = try #require(harness.view.inputAccessoryView)
        let toggle = try #require(keyboardToggleButton(in: accessory))
        #expect(toggle.accessibilityLabel == "Hide Keyboard")

        toggle.sendActions(for: .touchUpInside)
        #expect(toggle.accessibilityLabel == "Show Keyboard")

        toggle.sendActions(for: .touchUpInside)
        #expect(toggle.accessibilityLabel == "Hide Keyboard")
    }

    @Test("composer growth preserves the key-plane reservation before the next keyboard frame")
    func composerGrowthPreservesKeyboardKeyPlane() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        deliverKeyboardTransition(coveringBottom: Self.keyboardHeight, to: harness)
        let before = try #require(probeValue(of: harness.view, key: "keyboardHeight"))

        harness.view.setComposerBandHeight(120, animated: false)
        harness.view.setNeedsLayout()
        harness.view.layoutIfNeeded()

        // Accessory self-sizing can move the dock before UIKit posts a matching
        // keyboard frame. The old tracked total must not be reinterpreted using
        // the new accessory height, or the key-plane reservation shrinks by the
        // exact amount the composer grew and terminal rows sit under the dock.
        let after = try #require(probeValue(of: harness.view, key: "keyboardHeight"))
        #expect(abs(after - before) <= 1)
    }
}
#endif
