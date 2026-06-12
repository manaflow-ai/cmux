import AppKit
import Bonsplit
import SwiftUI


// MARK: - Minimal-mode sidebar titlebar controls metrics and frames
enum MinimalModeSidebarTitlebarControlsMetrics {
    static var leadingInset: CGFloat {
        leadingInset()
    }

    static var topInset: CGFloat {
        topInset()
    }

    static func leadingInset(defaults: UserDefaults = .standard) -> CGFloat {
        MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults)
    }

    static func topInset(defaults: UserDefaults = .standard) -> CGFloat {
        MinimalModeTitlebarDebugSettings.leftControlsTopInset(defaults: defaults)
    }

    static let hostWidth: CGFloat = 164
    static let hostHeight: CGFloat = 28

    static func titlebarControlsOpticalYOffset(backingScaleFactor _: CGFloat?) -> CGFloat {
        0
    }

    @MainActor
    static func titlebarControlsOpticalYOffset(in window: NSWindow?) -> CGFloat {
        titlebarControlsOpticalYOffset(
            backingScaleFactor: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor
        )
    }
}

@MainActor
func minimalModeSidebarTitlebarControlsFrame(
    in window: NSWindow,
    defaults: UserDefaults = .standard
) -> NSRect {
    let contentView = window.contentView
    let contentBounds = contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    let trafficLightFrameInContent = minimalModeTrafficLightFrameInContentCoordinates(for: window)
    return minimalModeSidebarTitlebarControlsFrame(
        contentBounds: contentBounds,
        contentViewIsFlipped: contentView?.isFlipped ?? false,
        trafficLightFrameInContent: trafficLightFrameInContent,
        visualDownwardAdjustment: trafficLightFrameInContent == nil
            ? 0
            : MinimalModeSidebarTitlebarControlsMetrics.titlebarControlsOpticalYOffset(in: window),
        defaults: defaults
    )
}

@MainActor
func minimalModeSidebarTitlebarControlsTopInset(
    in window: NSWindow,
    defaults: UserDefaults = .standard
) -> CGFloat {
    guard let contentView = window.contentView else {
        return MinimalModeSidebarTitlebarControlsMetrics.topInset(defaults: defaults)
    }
    let controlsFrame = minimalModeSidebarTitlebarControlsFrame(in: window, defaults: defaults)
    if contentView.isFlipped {
        return controlsFrame.minY - contentView.bounds.minY
    }
    return contentView.bounds.maxY - controlsFrame.maxY
}

func minimalModeSidebarTitlebarControlsFrame(
    contentBounds: NSRect,
    contentViewIsFlipped: Bool,
    trafficLightFrameInContent: NSRect?,
    visualDownwardAdjustment: CGFloat = 0,
    defaults: UserDefaults = .standard
) -> NSRect {
    let hostHeight = MinimalModeSidebarTitlebarControlsMetrics.hostHeight
    let targetY: CGFloat
    if let trafficLightFrameInContent {
        let centeredY = trafficLightFrameInContent.midY - hostHeight / 2.0
        targetY = contentViewIsFlipped
            ? centeredY + visualDownwardAdjustment
            : centeredY - visualDownwardAdjustment
    } else {
        let topInset = MinimalModeSidebarTitlebarControlsMetrics.topInset(defaults: defaults)
        targetY = contentViewIsFlipped
            ? contentBounds.minY + topInset
            : max(0, contentBounds.maxY - hostHeight - topInset)
    }
    return NSRect(
        x: MinimalModeSidebarTitlebarControlsMetrics.leadingInset(defaults: defaults),
        y: targetY,
        width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
        height: hostHeight
    )
}

func minimalModeTrafficLightFrameInContentCoordinates(
    window: NSWindow,
    contentView: NSView
) -> NSRect? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let closeButton = window.standardWindowButton(.closeButton),
          let closeButtonSuperview = closeButton.superview else {
        return nil
    }
    return closeButtonSuperview.convert(closeButton.frame, to: contentView)
}

@MainActor
private func minimalModeTrafficLightFrameInContentCoordinates(for window: NSWindow) -> NSRect? {
    guard let contentView = window.contentView else { return nil }
    return minimalModeTrafficLightFrameInContentCoordinates(window: window, contentView: contentView)
}

