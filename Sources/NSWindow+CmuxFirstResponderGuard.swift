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


// MARK: - Swizzled makeFirstResponder guard
extension NSWindow {
    static func cmuxCommandPaletteOwnsFieldEditor(_ textView: NSTextView?, in window: NSWindow) -> Bool {
        guard let textView,
              textView.isFieldEditor,
              textView.window === window else {
            return false
        }

        if let ownerView = cmuxFieldEditorOwnerView(textView) {
            guard let container = cmuxCommandPaletteOverlayAncestor(of: ownerView) else {
                return false
            }
            return cmuxCommandPaletteOverlayIsPresented(container)
        }

        guard let container = cmuxCommandPaletteOverlayContainer(in: window) else {
            return false
        }

        return cmuxCommandPaletteOverlayIsPresented(container)
    }

    private static func cmuxCommandPaletteOverlayAncestor(of view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    private static func cmuxCommandPaletteOverlayIsPresented(_ container: NSView) -> Bool {
        !container.isHidden && container.alphaValue > 0.001
    }

    private static func cmuxCommandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else {
            return nil
        }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    @objc func cmux_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if cmuxIsWindowFirstResponderBypassActive() {
#if DEBUG
            cmuxDebugLog(
                "focus.guard bypassFirstResponder responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        let currentEvent = Self.cmuxCurrentEvent(for: self)
        let responderWebView = responder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: currentEvent)
        }
        var pointerInitiatedWebFocus = false
        var pointerInitiatedTerminalFocus = false

        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
#if DEBUG
            cmuxDebugLog(
                "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if let request = AppDelegate.shared?.terminalKeyboardFocusRequest(for: responder),
           Self.cmuxShouldAllowPointerInitiatedTerminalFocus(
               window: self,
               request: request,
               event: currentEvent
           ) {
            pointerInitiatedTerminalFocus = true
            AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                workspaceId: request.workspaceId,
                panelId: request.panelId,
                in: self
            )
#if DEBUG
            cmuxDebugLog(
                "focus.guard allowPointerTerminalFirstResponder " +
                "window=\(ObjectIdentifier(self)) " +
                "workspace=\(request.workspaceId.uuidString.prefix(5)) " +
                "panel=\(request.panelId.uuidString.prefix(5)) " +
                "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
            )
#endif
        }

        if let responder,
           AppDelegate.shared?.allowsTerminalKeyboardFocus(for: responder, in: self) == false {
#if DEBUG
            if let request = AppDelegate.shared?.terminalKeyboardFocusRequest(for: responder) {
                dlog(
                    "focus.guard blockedTerminalFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "workspace=\(request.workspaceId.uuidString.prefix(5)) " +
                    "panel=\(request.panelId.uuidString.prefix(5))"
                )
            } else {
                dlog(
                    "focus.guard blockedTerminalFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self))"
                )
            }
#endif
            return false
        }

        if let responder,
           let webView = responderWebView,
           !webView.allowsFirstResponderAcquisitionEffective {
            let pointerInitiatedFocus = Self.cmuxShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
                pointerInitiatedWebFocus = true
#if DEBUG
                cmuxDebugLog(
                    "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
            } else {
#if DEBUG
                cmuxDebugLog(
                    "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
                return false
            }
        }
#if DEBUG
        if let responder,
           let webView = responderWebView {
            cmuxDebugLog(
                "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                "window=\(ObjectIdentifier(self)) " +
                "web=\(ObjectIdentifier(webView)) " +
                "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
            )
        }
#endif
        let result: Bool
        if pointerInitiatedWebFocus, let webView = responderWebView {
            // `NSWindow.makeFirstResponder` may run before `CmuxWebView.mouseDown(with:)`.
            // Preserve pointer intent during this synchronous responder change.
            result = webView.withPointerFocusAllowance {
                cmux_makeFirstResponder(responder)
            }
        } else {
            result = cmux_makeFirstResponder(responder)
        }
        if result {
            if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            } else if let fieldEditor = self.firstResponder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            }
            AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: self)
        } else if pointerInitiatedTerminalFocus {
            AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: self)
        }
        return result
    }

}
