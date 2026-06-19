#if DEBUG
import AppKit
import ObjectiveC.runtime

final class DebugShortcutRoutingFocusedWindowOverrideForTesting {
    weak var window: NSWindow?
    weak var keyRepairFirstResponder: NSResponder?
}

let debugShortcutRoutingFocusedWindowOverrideForTesting = DebugShortcutRoutingFocusedWindowOverrideForTesting()

private enum AppDelegateShortcutRoutingTestingSwizzles {
    static let didInstallWindowMakeKeyAndOrderFront: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeKeyAndOrderFront(_:))
        let swizzledSelector = #selector(NSWindow.cmux_makeKeyAndOrderFront(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
}

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

    static func installShortcutRoutingFocusedWindowSwizzleForTesting() {
        _ = AppDelegateShortcutRoutingTestingSwizzles.didInstallWindowMakeKeyAndOrderFront
    }
}

extension NSWindow {
    @objc func cmux_makeKeyAndOrderFront(_ sender: Any?) {
        cmux_makeKeyAndOrderFront(sender)
        AppDelegate.shared?.debugSetShortcutRoutingFocusedWindowForTesting(self)
    }
}
#endif
