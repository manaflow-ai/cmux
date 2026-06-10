import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - First responder guard state and NSApplication event swizzles
#if DEBUG
var cmuxFirstResponderGuardCurrentEventOverride: NSEvent?
var cmuxFirstResponderGuardHitViewOverride: NSView?
#endif
var cmuxFirstResponderGuardCurrentEventContext: NSEvent?
var cmuxFirstResponderGuardHitViewContext: NSView?
var cmuxFirstResponderGuardContextWindowNumber: Int?
var cmuxBrowserReturnForwardingDepth = 0
var cmuxBrowserArrowForwardingDepth = 0
var cmuxBrowserOmnibarMarkedTextForwardingDepth = 0
var cmuxCommandPaletteArrowForwardingDepth = 0
var cmuxTextBoxInputArrowForwardingDepth = 0
var cmuxTextBoxInputControlNavForwardingDepth = 0
var cmuxEditableTextViewArrowForwardingDepth = 0
private var cmuxWindowFirstResponderBypassDepth = 0
var cmuxFieldEditorOwningWebViewAssociationKey: UInt8 = 0

@discardableResult
func cmuxWithWindowFirstResponderBypass<T>(_ body: () -> T) -> T {
    cmuxWindowFirstResponderBypassDepth += 1
    defer {
        cmuxWindowFirstResponderBypassDepth = max(0, cmuxWindowFirstResponderBypassDepth - 1)
    }
    return body()
}

func cmuxIsWindowFirstResponderBypassActive() -> Bool {
    cmuxWindowFirstResponderBypassDepth > 0
}

final class CmuxFieldEditorOwningWebViewBox: NSObject {
    weak var webView: CmuxWebView?

    init(webView: CmuxWebView?) {
        self.webView = webView
    }
}

extension NSApplication {
    @objc func cmux_accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if Thread.isMainThread {
            switch CmuxApplicationAccessibilityHierarchyCache.shared.resolve(
                attribute: attribute,
                application: self
            ) {
            case .handled(let value):
                return value
            case .passthrough:
                break
            }
        }

        return cmux_accessibilityAttributeValue(attribute)
    }

    @objc func cmux_applicationSendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        if event.type == .keyDown {
            CmuxTypingTiming.logEventDelay(path: "app.sendEvent", event: event)
        }
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "app.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [("dispatchMs", totalMs)]
                )
                CmuxTypingTiming.logDuration(
                    path: "app.sendEvent",
                    startedAt: typingTimingStart,
                    event: event
                )
            }
        }
#endif
        if event.type == .leftMouseDown,
           AppDelegate.shared?.handleMinimalModeTitlebarDoubleClickMouseDown(event: event) == true {
            return
        }
        if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(
            event,
            preferredWindow: event.window ?? keyWindow ?? mainWindow
        ) {
            return
        }
        if AppDelegate.shared?.shouldSuppressStaleCmuxMenuShortcut(event: event) == true {
            if AppDelegate.shared?.handleConfiguredShortcutKeyEquivalent(event) == true {
#if DEBUG
                cmuxDebugLog("app.sendEvent routed configured shortcut before stale cmux menu shortcut")
#endif
                return
            }
            let responder = event.window?.firstResponder
                ?? keyWindow?.firstResponder
                ?? mainWindow?.firstResponder
            if let ghosttyView = cmuxOwningGhosttyView(for: responder) {
                ghosttyView.keyDown(with: event)
#if DEBUG
                cmuxDebugLog("app.sendEvent suppressed stale cmux menu shortcut and forwarded to terminal")
#endif
            } else {
#if DEBUG
                cmuxDebugLog("app.sendEvent suppressed stale cmux menu shortcut")
#endif
            }
            return
        }
        cmux_applicationSendEvent(event)
    }

    @objc func cmux_sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        if AppDelegate.shared?.handleDetachedInspectorWindowCloseAction(
            action: action,
            target: target,
            sender: sender
        ) == true {
            return true
        }

        return cmux_sendAction(action, to: target, from: sender)
    }
}

