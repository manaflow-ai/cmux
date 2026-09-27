#if DEBUG && canImport(UIKit)
import UIKit
import notify

extension GhosttySurfaceView {
    /// DEBUG-only: toggles the keyboard exactly like the toolbar keyboard
    /// button, so keyboard transitions can be recorded on a simulator without
    /// driving touch input:
    ///
    /// ```bash
    /// xcrun simctl spawn <udid> notifyutil -p dev.cmux.terminal.debug.keyboardToggle
    /// ```
    ///
    /// Only surfaces attached to a window listen, so the visible terminal
    /// receives the toggle.
    static let keyboardToggleDebugNotification = "dev.cmux.terminal.debug.keyboardToggle"
    /// Rotates between portrait and landscape through the scene API, the same
    /// transition coordinator path a device rotation drives:
    /// `notifyutil -p dev.cmux.terminal.debug.rotate`.
    static let rotateDebugNotification = "dev.cmux.terminal.debug.rotate"

    func syncKeyboardToggleDebugTrigger() {
        if window == nil {
            if keyboardToggleDebugToken != 0 {
                notify_cancel(keyboardToggleDebugToken)
                keyboardToggleDebugToken = 0
            }
            if rotateDebugToken != 0 {
                notify_cancel(rotateDebugToken)
                rotateDebugToken = 0
            }
            return
        }
        if rotateDebugToken == 0 {
            var rotateToken: Int32 = 0
            notify_register_dispatch(Self.rotateDebugNotification, &rotateToken, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let scene = self?.window?.windowScene else { return }
                    let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
                    scene.requestGeometryUpdate(
                        .iOS(interfaceOrientations: landscape ? .portrait : .landscapeRight)
                    ) { _ in }
                }
            }
            rotateDebugToken = rotateToken
        }
        guard keyboardToggleDebugToken == 0 else { return }
        var token: Int32 = 0
        notify_register_dispatch(Self.keyboardToggleDebugNotification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else { return }
                self.inputProxy.onHideKeyboard?()
            }
        }
        keyboardToggleDebugToken = token
    }
}
#endif
