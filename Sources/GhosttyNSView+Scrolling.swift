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


// MARK: - Scrollbar and rendered-frame updates, scroll wheel
extension GhosttyNSView {
    /// Coalesce high-frequency scrollbar updates into a single main-thread
    /// dispatch.  The action callback (which may fire thousands of times per
    /// second during bulk output like `seq 1 100000`) stores the latest value
    /// and schedules exactly one async flush.
    func enqueueScrollbarUpdate(_ newValue: GhosttyScrollbar) {
        _scrollbarLock.lock()
        defer { _scrollbarLock.unlock() }
        // Store the latest value (always overwrites — only the newest matters).
        _pendingScrollbar = newValue
        let needsSchedule = !_scrollbarFlushScheduled
        if needsSchedule { _scrollbarFlushScheduled = true }

        // If a flush is already scheduled, skip the dispatch — the scheduled
        // block will pick up the latest value.
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingScrollbar()
        }
    }

    func flushPendingScrollbar() {
        _scrollbarLock.lock()
        _scrollbarFlushScheduled = false
        let pending = _pendingScrollbar
        _pendingScrollbar = nil
        _scrollbarLock.unlock()

        guard let pending else { return }
        scrollbar = pending
        finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: pending)
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: self,
            userInfo: [GhosttyNotificationKey.scrollbar: pending]
        )
    }

    func flushPendingScrollbarIfAvailable() -> Bool {
        _scrollbarLock.lock()
        let hasPending = _pendingScrollbar != nil
        _scrollbarLock.unlock()

        guard hasPending else { return false }
        flushPendingScrollbar()
        return true
    }

    func enqueueRenderedFrameUpdate() {
        guard GhosttyRenderedFrameNotificationDemand.isActive else { return }

        _renderedFrameLock.lock()
        let needsSchedule = !_renderedFrameFlushScheduled
        if needsSchedule {
            _renderedFrameFlushScheduled = true
        }
        _renderedFrameLock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushRenderedFrameUpdate()
        }
    }

    private func flushRenderedFrameUpdate() {
        _renderedFrameLock.lock()
        _renderedFrameFlushScheduled = false
        _renderedFrameLock.unlock()

        guard GhosttyRenderedFrameNotificationDemand.isActive else { return }
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: self
        )
    }

    override func scrollWheel(with event: NSEvent) {
        NotificationCenter.default.post(name: .ghosttyDidReceiveWheelScroll, object: self)
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        // Track scroll state for lag detection
        let hasMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
        let momentumEnded = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        GhosttyApp.shared.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

}
