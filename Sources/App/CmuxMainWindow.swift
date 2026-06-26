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

    /// cmux owns main-window placement: it persists and restores window frames
    /// itself and disables AppKit window restoration (`isRestorable = false`),
    /// re-applying the saved frame only at startup.
    ///
    /// On a display/system sleep→wake (the kind a locked Mac eventually goes
    /// through — the lock keystroke itself is not the trigger) AppKit re-runs
    /// its constrain pass over every window. The default implementation does not
    /// only clamp off-screen windows back into view; it also repositions windows
    /// that are *already fully on-screen*, which is what we observe as the
    /// window creeping each sleep cycle. The exact reposition is AppKit-internal
    /// and depends on the display arrangement and each screen's menu-bar /
    /// safe-area insets, so it is neither a fixed titlebar-height nudge nor
    /// limited to a window whose titlebar sits under the menu bar — it also hits
    /// e.g. a window in the bottom half of an external display, and likely other
    /// arrangements. Because cmux never re-asserts the saved frame after wake,
    /// whatever the re-constrain produced sticks and accumulates.
    ///
    /// Fix: refuse the re-constrain for any frame that is already reachable on
    /// some screen, and defer to AppKit's default only when the frame would
    /// otherwise be stranded off-screen (e.g. a display was disconnected), so a
    /// genuinely lost window can still be pulled back into view.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if Self.shouldPreserveFrameDuringConstrain(
            frameRect,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        ) {
            return frameRect
        }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    /// Whether `proposedFrame` is reachable enough across `visibleFrames` that
    /// AppKit's constraining pass should be skipped.
    ///
    /// "Reachable" means a grabbable slice of the window's *titlebar* — its top
    /// strip — is on some screen's visible area, not merely that some corner of
    /// the window overlaps a screen. The main window is non-movable
    /// (``configureCmuxMainWindowDragBehavior`` sets `isMovable = false`) and can
    /// only be dragged by ``WindowDragHandleView`` in the titlebar band, so a
    /// window whose titlebar is off-screen cannot be recovered by the user even
    /// when its body still overlaps a display. Requiring the top strip to remain
    /// reachable lets AppKit re-clamp a window stranded above the screen (e.g.
    /// after disconnecting an external monitor that sat above the built-in
    /// display) while still leaving a genuinely on-screen frame untouched, which
    /// is what stops the sleep/wake drift (#6305).
    ///
    /// This mirrors the startup/restore-path reachability test
    /// (`AppDelegate.shouldPreserveAccessibleFrame`); the two are kept in sync so
    /// the runtime constrain pass is no weaker than the restore-time clamp.
    nonisolated static func shouldPreserveFrameDuringConstrain(
        _ proposedFrame: NSRect,
        visibleFrames: [NSRect],
        topStripHeight: CGFloat = 64,
        minimumVisibleTopStripWidth: CGFloat = 120,
        minimumVisibleTopStripHeight: CGFloat = 24
    ) -> Bool {
        let frame = proposedFrame.standardized
        guard frame.width > 0, frame.height > 0 else { return false }

        let stripHeight = min(topStripHeight, frame.height)
        let topStrip = NSRect(
            x: frame.minX,
            y: frame.maxY - stripHeight,
            width: frame.width,
            height: stripHeight
        )
        let requiredWidth = min(minimumVisibleTopStripWidth, frame.width)
        let requiredHeight = min(minimumVisibleTopStripHeight, stripHeight)

        for visibleFrame in visibleFrames {
            let intersection = topStrip.intersection(visibleFrame)
            if intersection.width >= requiredWidth, intersection.height >= requiredHeight {
                return true
            }
        }
        return false
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
