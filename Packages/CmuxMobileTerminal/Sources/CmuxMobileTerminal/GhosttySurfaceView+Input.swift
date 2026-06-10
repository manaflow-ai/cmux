#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

// MARK: - Text Input, Focus & Keyboard
extension GhosttySurfaceView {
    @objc func handleKeyboardWillShow(_ notification: Notification) {
        guard let frameEnd = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window else { return }
        let keyboardFrameInView = convert(frameEnd, from: window)
        let overlap = max(0, bounds.maxY - keyboardFrameInView.minY)
        guard overlap != keyboardHeight else { return }
        keyboardHeight = overlap
        inputProxy.setKeyboardShown(true)
        animateDockedToolbar(with: notification)
        setNeedsGeometrySync()
    }

    @objc func handleKeyboardWillHide(_ notification: Notification) {
        guard keyboardHeight != 0 else { return }
        keyboardHeight = 0
        inputProxy.setKeyboardShown(false)
        animateDockedToolbar(with: notification)
        setNeedsGeometrySync()
        // No explicit scrollback request here: the grid grew, so the viewport
        // report resizes the Mac surface and the producer exports the taller
        // viewport (which reveals more history) on its own.
    }

    #if DEBUG
    /// Test seam: force a synthetic keyboard height so the keyboard-up layout
    /// (docked toolbar riding the keyboard edge, grid reserving toolbar +
    /// keyboard) can be screenshotted on the simulator, which refuses to render
    /// the software keyboard. Drives the exact same geometry path as a real
    /// keyboard. Used only by the terminal-layout preview harness.
    public func debugSetKeyboardHeightForLayoutPreview(_ height: CGFloat) {
        keyboardHeight = max(0, height)
        inputProxy.setKeyboardShown(height > 0)
        layoutDockedToolbar()
        setNeedsGeometrySync()
        setNeedsLayout()
    }

    /// Test seam: present the zoom-control overlay (normally only shown on a
    /// pinch, which the simulator can't do) pinned visible so its appearance
    /// can be screenshotted.
    public func debugShowZoomControlOverlayForPreview() {
        showZoomOverlay()
        zoomOverlayLastInteraction = CACurrentMediaTime() + 3600
    }
    #endif

    /// Dock the accessory bar as a persistent bottom toolbar. Frame-positioned
    /// (not `keyboardLayoutGuide`-pinned) so it uses the exact same bottom
    /// occupancy as the grid reservation and the two never disagree. The grid
    /// reserves its height (see `reservedToolbarHeight`) so the bottom TUI rows
    /// stay visible above it.
    func installPersistentToolbar() {
        let toolbar = inputProxy.toolbarView
        addSubview(toolbar)
        dockedToolbar = toolbar
        reservedToolbarHeight = Self.persistentToolbarHeight
        layoutDockedToolbar()
    }

    /// Full-width bar whose bottom sits on the keyboard (when up) or the very
    /// bottom edge (when down). It intentionally does NOT reserve the bottom
    /// safe area: the toolbar IS the bottom chrome, so the home indicator simply
    /// overlays its lower edge (like a system tab bar) instead of leaving an
    /// empty strip below it. Mirrors the `bottomInset` math in
    /// `syncSurfaceGeometry` so the toolbar top equals the grid bottom exactly.
    func dockedToolbarFrame() -> CGRect {
        let occupied = max(0, keyboardHeight)
        let height = Self.persistentToolbarHeight
        return CGRect(x: 0, y: bounds.height - height - occupied, width: bounds.width, height: height)
    }

    func layoutDockedToolbar() {
        dockedToolbar?.frame = dockedToolbarFrame()
    }

    /// Animate the docked toolbar in lockstep with a keyboard show/hide so it
    /// rides the keyboard edge instead of jumping. There is no interactive
    /// (swipe-down) dismissal in this terminal, so a notification-driven animate
    /// is sufficient and avoids the `keyboardLayoutGuide` safe-area mismatch.
    private func animateDockedToolbar(with notification: Notification) {
        guard let dockedToolbar else { return }
        let target = dockedToolbarFrame()
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16)
        ) {
            dockedToolbar.frame = target
        }
    }

    @objc
    func focusInput() {
        onFocusInputRequestedForTesting?()
        Self.activeInputSurface = self
        setNeedsGeometrySync()
        inputProxy.updateAccessoryLayoutInsets()
        inputProxy.becomeFirstResponder()
    }

    /// Resigns the currently focused terminal input proxy, if any.
    ///
    /// Use before presenting SwiftUI chrome over the terminal so UIKit releases
    /// the hidden text input and the terminal can recalculate full-height
    /// geometry after the keyboard leaves.
    public static func resignActiveInput() {
        activeInputSurface?.resignInput()
    }

    /// Resigns this surface's hidden text input and clears keyboard geometry.
    public func resignInput() {
        inputProxy.resignFirstResponder()
        if Self.activeInputSurface === self {
            Self.activeInputSurface = nil
        }
        // Don't zero `keyboardHeight` here. `resignFirstResponder()` triggers
        // `keyboardWillHide`, which owns the full hide cleanup (proxy state,
        // docked-toolbar animation, geometry). Pre-zeroing would make that
        // handler's `keyboardHeight != 0` guard short-circuit, leaving the
        // toolbar at the old keyboard edge with a stale glyph.
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        let count = normalized.utf8CString.count
        guard count > 1 else { return }
        normalized.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(count - 1))
        }
    }

    func sendPaste(_ text: String) {
        guard let surface else { return }
        let count = text.utf8CString.count
        guard count > 0 else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(count - 1))
        }
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

}

#endif
