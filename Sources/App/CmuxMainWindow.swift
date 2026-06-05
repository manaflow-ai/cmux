import AppKit
import SwiftUI

final class MainWindowHostingView<Content: View>: NSHostingView<Content> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }
    override var mouseDownCanMoveWindow: Bool { false }
    override var fittingSize: NSSize { CmuxMainWindow.minimumContentSize }
    override var intrinsicContentSize: NSSize { CmuxMainWindow.minimumContentSize }

    /// Lets a click on an interactive titlebar control (the sidebar toggle, the
    /// right-sidebar mode bar, the session-index header controls, etc.) both
    /// activate the window and trigger the control in a single click when the
    /// window is inactive — matching how macOS services controls in the titlebar.
    ///
    /// Scoped to registered ``MinimalModeTitlebarControlHitRegionRegistry`` regions
    /// (the regions `titlebarInteractiveControl()` registers) so clicking inactive
    /// *content* still only activates the window. This recovers the first-mouse
    /// behavior the previous nested-`NSHostingView` host provided, without
    /// reparenting the control (which dropped active-window clicks in the
    /// full-size-content titlebar band — issue #5099).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event, let window else { return false }
        return isMinimalModeTitlebarControlHit(window: window, locationInWindow: event.locationInWindow)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    deinit {}

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
func configureCmuxMainWindowDragBehavior(_ window: NSWindow) {
    window.isMovableByWindowBackground = false
    window.isMovable = false
}

@MainActor
final class CmuxMainWindow: NSWindow {
    static var minimumContentSize: NSSize {
        NSSize(
            width: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
            height: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        )
    }

    static func standardFrame(forDefaultFrame defaultFrame: NSRect) -> NSRect {
        let minimumSize = minimumContentSize
        var frame = defaultFrame
        frame.size.width = max(frame.size.width, minimumSize.width)
        frame.size.height = max(frame.size.height, minimumSize.height)
        return frame
    }

    private var isSoftHiddenForVisibilityController = false

    func setSoftHiddenForVisibilityController(_ isSoftHidden: Bool) {
        isSoftHiddenForVisibilityController = isSoftHidden
        if isSoftHidden {
            makeFirstResponder(nil)
            ignoresMouseEvents = true
            alphaValue = 0
        } else {
            alphaValue = 1
            ignoresMouseEvents = false
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !isSoftHiddenForVisibilityController else { return }
        super.flagsChanged(with: event)
    }
}

extension CmuxMainWindow {
    private static let defaultContentSize = NSSize(width: 1_000, height: 700)

    /// Returns an unpositioned content rect clamped to the visible display; callers own final placement.
    static func defaultContentRect(styleMask: NSWindow.StyleMask) -> NSRect {
        let unpositionedContentRect = NSRect(origin: .zero, size: defaultContentSize)
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return unpositionedContentRect
        }

        let frameRect = NSWindow.frameRect(forContentRect: unpositionedContentRect, styleMask: styleMask)
        let clampedFrameRect = clampedFrame(frameRect, within: visibleFrame)
        return NSWindow.contentRect(forFrameRect: clampedFrameRect, styleMask: styleMask)
    }

    private static func clampedFrame(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let width = min(max(frame.width, defaultContentSize.width), visibleFrame.width)
        let height = min(max(frame.height, defaultContentSize.height), visibleFrame.height)
        return NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }
}
