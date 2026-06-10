import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - First responder and focus management
extension GhosttyNSView {
    static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        AppDelegate.shared?.focusLog.append(message)
        #if DEBUG
        NSLog("[FOCUSDBG] %@", message)
        #endif
    }

    private var hasUsableFocusGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    static func shouldRequestFirstResponderForMouseFocus(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }

    // Visibility is used for focus gating. Explicit portal visibility transitions
    // also drive Ghostty occlusion so hidden workspace/split surfaces pause and
    // queue a redraw when they become visible again.
    var isVisibleInUI: Bool { visibleInUI }
    func setVisibleInUI(_ visible: Bool) {
        visibleInUI = visible
    }

    @discardableResult
    func ensureSurfaceReadyForInput() -> ghostty_surface_t? {
        if let surface = surface {
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToView(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        return surface
    }

    func requestInputRecoveryAfterSurfaceMiss(reason: String) {
        terminalSurface?.requestBackgroundSurfaceStartIfNeeded()
#if DEBUG
        cmuxDebugLog(
            "focus.input_recovery surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) inWindow=\(window != nil ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func prepareSurfaceForPaste(reason: String) -> Bool {
        guard ensureSurfaceReadyForInput() != nil else {
            requestInputRecoveryAfterSurfaceMiss(reason: reason)
            return false
        }
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        var shouldApplySurfaceFocus = false
        if result {
            imeConsumedKeyUps.removeAll()
            if let terminalSurface,
               AppDelegate.shared?.allowsTerminalKeyboardFocus(
                   workspaceId: terminalSurface.tabId,
                   panelId: terminalSurface.id,
                   in: window
               ) == false {
                desiredFocus = false
                terminalSurface.recordExternalFocusState(false)
#if DEBUG
                dlog("focus.firstResponder SUPPRESSED (coordinator) surface=\(terminalSurface.id.uuidString.prefix(5))")
#endif
                return result
            }

            // If we become first responder before the ghostty surface exists (e.g. during
            // split/tab creation while the surface is still being created), record the desired focus.
            desiredFocus = true

            // During programmatic splits, SwiftUI reparents the old NSView which triggers
            // becomeFirstResponder. Suppress onFocus + ghostty_surface_set_focus to prevent
            // the old view from stealing focus and creating model/surface divergence.
            if suppressingReparentFocus {
#if DEBUG
                cmuxDebugLog("focus.firstResponder SUPPRESSED (reparent) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                return result
            }

            // Always notify the host app that this pane became the first responder so bonsplit
            // focus/selection can converge. Previously this was gated on `surface != nil`, which
            // allowed a mismatch where AppKit focus moved but the UI focus indicator (bonsplit)
            // stayed behind.
            let hiddenInHierarchy = isHiddenOrHasHiddenAncestor
            if isVisibleInUI && hasUsableFocusGeometry && !hiddenInHierarchy {
                shouldApplySurfaceFocus = true
                onFocus?()
            } else if isVisibleInUI && (!hasUsableFocusGeometry || hiddenInHierarchy) {
#if DEBUG
                cmuxDebugLog(
                    "focus.firstResponder SUPPRESSED (hidden_or_tiny) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) hidden=\(hiddenInHierarchy ? 1 : 0)"
                )
#endif
            }
        }
        if result, shouldApplySurfaceFocus, let surface = ensureSurfaceReadyForInput() {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
#if DEBUG
            cmuxDebugLog("focus.firstResponder surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            if let terminalSurface {
                NotificationCenter.default.post(
                    name: .ghosttyDidBecomeFirstResponderSurface,
                    object: nil,
                    userInfo: [
                        GhosttyNotificationKey.tabId: terminalSurface.tabId,
                        GhosttyNotificationKey.surfaceId: terminalSurface.id,
                    ]
                )
            }
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)

            // Ghostty only restarts its vsync display link on display-id changes while focused.
            // During rapid split close / SwiftUI reparenting, the view can reattach to a window
            // and get its display id set *before* it becomes first responder; in that case, the
            // renderer can remain stuck until some later screen/focus transition. Reassert the
            // display id now that we're focused to ensure the renderer is running.
            if let displayID = window?.screen?.displayID, displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
            terminalSurface?.forceRefresh(reason: "focus.firstResponder")
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            imeConsumedKeyUps.removeAll()
            desiredFocus = false
            terminalSurface?.recordExternalFocusState(false)
        }
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("resignFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    func requestPointerFocusRecovery() {
#if DEBUG
        cmuxDebugLog("focus.pointerDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
        onFocus?()
    }

    func maybeRequestFirstResponderForMouseFocus() {
        guard let window else { return }
        let alreadyFirstResponder = window.firstResponder === self
        let shouldRequest = Self.shouldRequestFirstResponderForMouseFocus(
            focusFollowsMouseEnabled: GhosttyApp.shared.focusFollowsMouseEnabled(),
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            appIsActive: NSApp.isActive,
            windowIsKey: window.isKeyWindow,
            alreadyFirstResponder: alreadyFirstResponder,
            visibleInUI: isVisibleInUI,
            hasUsableGeometry: hasUsableFocusGeometry,
            hiddenInHierarchy: isHiddenOrHasHiddenAncestor
        )
        guard shouldRequest else { return }
        window.makeFirstResponder(self)
    }

}
