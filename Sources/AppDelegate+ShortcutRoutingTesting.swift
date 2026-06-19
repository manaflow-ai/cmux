#if DEBUG
import AppKit
import ObjectiveC.runtime

final class DebugShortcutRoutingFocusedWindowOverrideForTesting {
    weak var window: NSWindow?
    weak var keyRepairFirstResponder: NSResponder?
    var focusedWindowCaptureDepth = 0

    var shouldCaptureFocusedWindow: Bool {
        focusedWindowCaptureDepth > 0
    }
}

let debugShortcutRoutingFocusedWindowOverrideForTesting = DebugShortcutRoutingFocusedWindowOverrideForTesting()

private let didInstallShortcutRoutingWindowMakeKeyAndOrderFrontSwizzleForTesting: Void = {
    let targetClass: AnyClass = NSWindow.self
    let originalSelector = #selector(NSWindow.makeKeyAndOrderFront(_:))
    let swizzledSelector = #selector(NSWindow.cmux_makeKeyAndOrderFront(_:))
    guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
          let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
        return
    }
    method_exchangeImplementations(originalMethod, swizzledMethod)
}()

extension AppDelegate {
    func debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: Bool = true) {
        clearConfiguredShortcutChordState()
        shortcutEventFocusContextCache = nil
        debugShortcutRoutingFocusedWindowOverrideForTesting.keyRepairFirstResponder = nil
        debugFocusedTerminalKeyRepairObserverForTesting = nil
        if clearFocusedWindowOverride {
            debugShortcutRoutingFocusedWindowOverrideForTesting.window = nil
        }
    }

    func debugSetShortcutRoutingFocusedWindowForTesting(_ window: NSWindow?) {
        debugShortcutRoutingFocusedWindowOverrideForTesting.window = window
        shortcutEventFocusContextCache = nil
    }

    func debugSetShortcutRoutingKeyRepairFirstResponderForTesting(_ responder: NSResponder?) {
        debugShortcutRoutingFocusedWindowOverrideForTesting.keyRepairFirstResponder = responder
    }

    func debugBeginShortcutRoutingFocusedWindowCaptureForTesting() {
        debugShortcutRoutingFocusedWindowOverrideForTesting.focusedWindowCaptureDepth += 1
        debugResetShortcutRoutingStateForTesting()
    }

    func debugEndShortcutRoutingFocusedWindowCaptureForTesting() {
        let override = debugShortcutRoutingFocusedWindowOverrideForTesting
        override.focusedWindowCaptureDepth = max(override.focusedWindowCaptureDepth - 1, 0)
        debugResetShortcutRoutingStateForTesting()
    }

    static func installShortcutRoutingFocusedWindowSwizzleForTesting() {
        _ = didInstallShortcutRoutingWindowMakeKeyAndOrderFrontSwizzleForTesting
    }
}

extension NSWindow {
    @objc func cmux_makeKeyAndOrderFront(_ sender: Any?) {
        cmux_makeKeyAndOrderFront(sender)
        guard debugShortcutRoutingFocusedWindowOverrideForTesting.shouldCaptureFocusedWindow else {
            return
        }
        AppDelegate.shared?.debugSetShortcutRoutingFocusedWindowForTesting(self)
    }
}
#endif
