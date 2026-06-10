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


// MARK: - Mouse event handling
extension GhosttyNSView {
    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        let debugPoint = convert(event.locationInWindow, from: nil)
        cmuxDebugLog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))] clickCount=\(event.clickCount) point=(\(String(format: "%.0f", debugPoint.x)),\(String(format: "%.0f", debugPoint.y)))")
        #endif
        // Split reparent/layout churn can suppress the later `becomeFirstResponder -> onFocus`
        // callback. Treat pointer-down as explicit focus intent so clicking a ghost pane still
        // repairs workspace/pane active state before key routing runs.
        if let terminalSurface {
            if terminalSurface.focusPlacement == .rightSidebarDock {
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
            } else {
                AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                    workspaceId: terminalSurface.tabId,
                    panelId: terminalSurface.id,
                    in: window
                )
            }
            terminalSurface.hostedView.clearReparentFocusSuppressionForPointerFocus()
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        if let terminalSurface {
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        }
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Only update mouse position on the first click to prevent unwanted cursor
        // movement during double-click selection (issue #1698)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        hasPendingLeftMouseRelease = true
    }

    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        cmuxDebugLog("terminal.mouseUp surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))]")
        #endif
        completePendingLeftMouseRelease(with: event)
    }

    @discardableResult
    func forwardPendingLeftMouseDrag(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease, let surface else { return false }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
        return true
    }

    @discardableResult
    func completePendingLeftMouseRelease(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease else { return false }
        hasPendingLeftMouseRelease = false
        guard let surface else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        _ = handleCommandClickRelease(at: point, modifierFlags: event.modifierFlags, ghosttyConsumed: consumed)
        return true
    }

    private func clampedDebugPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, 1), max(bounds.width - 1, 1)),
            y: min(max(point.y, 1), max(bounds.height - 1, 1))
        )
    }

#if DEBUG
    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        guard let surface else { return false }
        let start = clampedDebugPoint(startPoint)
        let end = clampedDebugPoint(endPoint)
        let mods = GHOSTTY_MODS_NONE

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, start.x, bounds.height - start.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)

        let steps = max(4, Int(max(abs(end.x - start.x), abs(end.y - start.y)) / max(cellSize.width, 1)))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = NSPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            let clampedIntermediatePoint = clampedDebugPoint(intermediatePoint)
            ghostty_surface_mouse_pos(
                surface,
                clampedIntermediatePoint.x,
                bounds.height - clampedIntermediatePoint.y,
                mods
            )
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        return ghostty_surface_has_selection(surface)
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        guard let surface else { return false }
        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )
        return suppressCommandPathHover
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )

        let resolution = suppressCommandPathHover ? nil : resolveWordUnderCursorPath(at: clampedPoint)
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )

        var payload: [String: Any] = [
            "hoverActive": wordPathHoverActive ? "1" : "0",
            "suppressed": suppressCommandPathHover ? "1" : "0"
        ]
        if let resolution {
            payload["resolvedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let mods = modsFromFlags(flags)

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, mods)
        let pressHandled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        let releaseConsumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        let resolution = handleCommandClickRelease(
            at: clampedPoint,
            modifierFlags: flags,
            ghosttyConsumed: releaseConsumed
        )

        var payload: [String: Any] = [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": releaseConsumed ? "1" : "0",
        ]
        if let resolution {
            payload["openedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }
#endif

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            requestPointerFocusRecovery()
            super.rightMouseDown(with: event)
            return
        }

        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    override func mouseExited(with event: NSEvent) {
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Forward the raw drag coordinates, including out-of-bounds positions.
        // Selection auto-scroll depends on libghostty observing the pointer leave
        // the viewport rather than a cached in-bounds hover point.
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
    }

#if DEBUG
    func debugHasPendingLeftMouseReleaseForTesting() -> Bool {
        hasPendingLeftMouseRelease
    }
#endif

}
