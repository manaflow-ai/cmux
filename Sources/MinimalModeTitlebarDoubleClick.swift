import AppKit
import Bonsplit
import SwiftUI


// MARK: - Minimal-mode titlebar double-click detection
func shouldHandleMinimalModeTitlebarDoubleClick(
    isEnabled: Bool,
    clickCount: Int,
    point: NSPoint,
    bounds: NSRect,
    topStripHeight: CGFloat
) -> Bool {
    guard clickCount >= 2 else {
        return false
    }
    return isPointInMinimalModeTitlebarBand(
        isEnabled: isEnabled,
        point: point,
        bounds: bounds,
        topStripHeight: topStripHeight
    )
}

func isPointInMinimalModeTitlebarBand(
    isEnabled: Bool,
    point: NSPoint,
    bounds: NSRect,
    topStripHeight: CGFloat
) -> Bool {
    guard isEnabled, topStripHeight > 0, bounds.contains(point) else {
        return false
    }
    let clampedHeight = min(max(0, topStripHeight), bounds.height)
    return point.y >= bounds.maxY - clampedHeight
}

struct MinimalModeTitlebarClickRecord: Equatable {
    let windowNumber: Int
    let timestamp: TimeInterval
    let locationInWindow: NSPoint
}

func minimalModeTitlebarClickFormsDoubleClick(
    clickCount: Int,
    timestamp: TimeInterval,
    locationInWindow: NSPoint,
    windowNumber: Int,
    previous: MinimalModeTitlebarClickRecord?,
    doubleClickInterval: TimeInterval,
    doubleClickIntervalTolerance: TimeInterval = 0,
    maxDistance: CGFloat = 4
) -> Bool {
    if clickCount >= 2 {
        return true
    }
    let allowedInterval = max(0, doubleClickInterval) + max(0, doubleClickIntervalTolerance)
    guard let previous,
          previous.windowNumber == windowNumber,
          timestamp - previous.timestamp >= 0,
          timestamp - previous.timestamp <= allowedInterval else {
        return false
    }

    let dx = locationInWindow.x - previous.locationInWindow.x
    let dy = locationInWindow.y - previous.locationInWindow.y
    return hypot(dx, dy) <= maxDistance
}

let minimalModeTitlebarSyntheticDoubleClickTolerance: TimeInterval = {
    #if DEBUG
    0.15
    #else
    0
    #endif
}()

func minimalModeTitlebarDoubleClickBandHeight(for window: NSWindow) -> CGFloat {
    MinimalModeChromeMetrics.titlebarHeight
}

func isMainWorkspaceWindow(_ window: NSWindow) -> Bool {
    guard let raw = window.identifier?.rawValue else { return false }
    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
}

func shouldHandleMinimalModeWindowTitlebarDoubleClick(
    isMinimalMode: Bool,
    isFullScreen: Bool,
    isMainWindow: Bool,
    clickCount: Int,
    locationInWindow: NSPoint,
    contentBounds: NSRect,
    titlebarBandHeight: CGFloat
) -> Bool {
    shouldHandleMinimalModeTitlebarDoubleClick(
        isEnabled: isMinimalMode && !isFullScreen && isMainWindow,
        clickCount: clickCount,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: titlebarBandHeight
    )
}

func isMinimalModeWindowTitlebarClickCandidate(
    isMinimalMode: Bool,
    isFullScreen: Bool,
    isMainWindow: Bool,
    locationInWindow: NSPoint,
    contentBounds: NSRect,
    titlebarBandHeight: CGFloat
) -> Bool {
    isPointInMinimalModeTitlebarBand(
        isEnabled: isMinimalMode && !isFullScreen && isMainWindow,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: titlebarBandHeight
    )
}

func shouldHandleMinimalModeWindowTitlebarDoubleClick(
    window: NSWindow,
    event: NSEvent,
    defaults: UserDefaults = .standard
) -> Bool {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    return shouldHandleMinimalModeWindowTitlebarDoubleClick(
        isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults),
        isFullScreen: window.styleMask.contains(.fullScreen),
        isMainWindow: isMainWorkspaceWindow(window),
        clickCount: event.clickCount,
        locationInWindow: event.locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
    )
}

func isMinimalModeWindowTitlebarClickCandidate(
    window: NSWindow,
    event: NSEvent,
    defaults: UserDefaults = .standard
) -> Bool {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    return isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: WorkspacePresentationModeSettings.isMinimal(defaults: defaults),
        isFullScreen: window.styleMask.contains(.fullScreen),
        isMainWindow: isMainWorkspaceWindow(window),
        locationInWindow: event.locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
    )
}

