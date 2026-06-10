import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Pointer focus allowance and mouse button handling
extension CmuxWebView {
    // Some sites/WebKit paths report middle-click link activations as
    // WKNavigationAction.buttonNumber=4 instead of 2. Track a recent local
    // middle-click so navigation delegates can recover intent reliably.
    private struct MiddleClickIntent {
        let webViewID: ObjectIdentifier
        let uptime: TimeInterval
    }

    private static var lastMiddleClickIntent: MiddleClickIntent?
    private static let middleClickIntentMaxAge: TimeInterval = 0.8
    static func hasRecentMiddleClickIntent(for webView: WKWebView) -> Bool {
        guard let webView = webView as? CmuxWebView else { return false }
        guard let intent = lastMiddleClickIntent else { return false }

        let age = ProcessInfo.processInfo.systemUptime - intent.uptime
        if age > middleClickIntentMaxAge {
            lastMiddleClickIntent = nil
            return false
        }

        return intent.webViewID == ObjectIdentifier(webView)
    }

    private static func recordMiddleClickIntent(for webView: CmuxWebView) {
        lastMiddleClickIntent = MiddleClickIntent(
            webViewID: ObjectIdentifier(webView),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    var allowsFirstResponderAcquisitionEffective: Bool {
        allowsFirstResponderAcquisition || pointerFocusAllowanceDepth > 0
    }
    var debugPointerFocusAllowanceDepth: Int { pointerFocusAllowanceDepth }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func becomeFirstResponder() -> Bool {
        guard allowsFirstResponderAcquisitionEffective else {
#if DEBUG
            let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
            cmuxDebugLog(
                "browser.focus.blockedBecome web=\(ObjectIdentifier(self)) " +
                "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
            )
#endif
            return false
        }
        let result = super.becomeFirstResponder()
        if result {
            let pointerInitiatedKey = BrowserFirstResponderNotificationUserInfoKey.pointerInitiated
            NotificationCenter.default.post(
                name: .browserDidBecomeFirstResponderWebView,
                object: self,
                userInfo: [pointerInitiatedKey: pointerFocusAllowanceDepth > 0]
            )
        }
#if DEBUG
        let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.become web=\(ObjectIdentifier(self)) result=\(result ? 1 : 0) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
        )
#endif
        return result
    }

    /// Temporarily permits focus acquisition for explicit pointer-driven interactions
    /// (mouse click into this webview) while keeping background autofocus blocked.
    func withPointerFocusAllowance<T>(_ body: () -> T) -> T {
        pointerFocusAllowanceDepth += 1
#if DEBUG
        cmuxDebugLog(
            "browser.focus.pointerAllowance.enter web=\(ObjectIdentifier(self)) " +
            "depth=\(pointerFocusAllowanceDepth)"
        )
#endif
        defer {
            pointerFocusAllowanceDepth = max(0, pointerFocusAllowanceDepth - 1)
#if DEBUG
            cmuxDebugLog(
                "browser.focus.pointerAllowance.exit web=\(ObjectIdentifier(self)) " +
                "depth=\(pointerFocusAllowanceDepth)"
            )
#endif
        }
        return body()
    }

    // The SwiftUI Color.clear overlay (.onTapGesture) that focuses panes can't receive
    // clicks when a WKWebView is underneath — AppKit delivers the click to the deepest
    // NSView (WKWebView), not to sibling SwiftUI overlays. Notify the panel system so
    // bonsplit focus tracks which pane the user clicked in.
    override func mouseDown(with event: NSEvent) {
#if DEBUG
        let windowNumber = window?.windowNumber ?? -1
        let firstResponderType = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.mouseDown web=\(ObjectIdentifier(self)) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) win=\(windowNumber) fr=\(firstResponderType)"
        )
#endif
        performBrowserClickFocusHandoff {
            super.mouseDown(with: event)
        }
    }

    private func performBrowserClickFocusHandoff(_ action: () -> Void) {
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: self)
        withPointerFocusAllowance(action)
    }

    // MARK: - Mouse back/forward buttons

    private func handleMouseNavigationButton(_ event: NSEvent) -> Bool {
        // Button 3 = back, button 4 = forward (multi-button mice like Logitech).
        // Consume the event so WebKit/page content does not also handle it.
        switch event.buttonNumber {
        case 3:
#if DEBUG
            cmuxDebugLog("browser.mouse.navigation web=\(ObjectIdentifier(self)) kind=back canGoBack=\(canGoBack ? 1 : 0)")
#endif
            if let onMouseBackButton {
                onMouseBackButton()
            } else {
                goBack()
            }
            return true
        case 4:
#if DEBUG
            cmuxDebugLog("browser.mouse.navigation web=\(ObjectIdentifier(self)) kind=forward canGoForward=\(canGoForward ? 1 : 0)")
#endif
            if let onMouseForwardButton {
                onMouseForwardButton()
            } else {
                goForward()
            }
            return true
        default:
            return false
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            Self.recordMiddleClickIntent(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        cmuxDebugLog(
            "browser.mouse.otherDown web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        if event.buttonNumber == 3 || event.buttonNumber == 4 {
            performBrowserClickFocusHandoff {
                _ = window?.makeFirstResponder(self)
            }
        }
        if handleMouseNavigationButton(event) {
            return
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            Self.recordMiddleClickIntent(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        cmuxDebugLog(
            "browser.mouse.otherUp web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        if event.buttonNumber == 3 || event.buttonNumber == 4 {
            return
        }
        super.otherMouseUp(with: event)
    }

}
