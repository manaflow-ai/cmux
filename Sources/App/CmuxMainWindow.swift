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
    /// AppKit's constraining pass should be skipped. The frame qualifies when it
    /// overlaps some screen's visible area by at least `minimumVisibleExtent`
    /// points in both dimensions (or its full extent, when smaller) — i.e. a
    /// usable, grabbable slice of the window is on-screen.
    nonisolated static func shouldPreserveFrameDuringConstrain(
        _ proposedFrame: NSRect,
        visibleFrames: [NSRect],
        minimumVisibleExtent: CGFloat = 60
    ) -> Bool {
        let requiredWidth = min(proposedFrame.width, minimumVisibleExtent)
        let requiredHeight = min(proposedFrame.height, minimumVisibleExtent)
        for visibleFrame in visibleFrames {
            let intersection = proposedFrame.intersection(visibleFrame)
            if intersection.width >= requiredWidth, intersection.height >= requiredHeight {
                return true
            }
        }
        return false
    }

    /// After the app has been inactive and a display sleep/wake or screen
    /// reconfiguration occurred, a main window can come back genuinely
    /// *resized* to a small frame — a native-fullscreen exit, an un-zoom
    /// revert, or a display-mode resize. ``constrainFrameRect(_:to:)`` cannot
    /// undo that: it only vetoes AppKit's re-constrain of an already-good
    /// frame, not a real resize applied through another path, so the shrunken
    /// frame sticks. This is issue #5492 — "goes from full screen to 2/3 of
    /// the screen after the terminal has lost focus for some time" (≈ the
    /// 1000×700 default window on a built-in MacBook display).
    ///
    /// A frame change while the app is inactive is never user-driven (the user
    /// is in another app), so reverting the window to the frame it had when the
    /// user last left it is safe. Returns the frame to restore (clamped to the
    /// screen it overlaps most), or `nil` when no restore is warranted: the
    /// window did not shrink meaningfully, or the pre-deactivation frame is no
    /// longer *substantially* on any current screen — its display was unplugged,
    /// or the display woke at a smaller mode — in which case the OS-adjusted
    /// on-screen frame is kept rather than restoring stale geometry.
    ///
    /// The containment bar is deliberately stricter than the 60pt reachability
    /// used by ``shouldPreserveFrameDuringConstrain(_:visibleFrames:)``: that
    /// bar is right for *not stranding* a window during a constrain pass, but a
    /// topology/resolution change while inactive can leave the old frame mostly
    /// off-screen (or larger than the current display) while still clearing
    /// 60pt, and restoring it then would push the window back off-screen.
    nonisolated static func restoredFrameAfterInactiveDisplayTransition(
        current: NSRect,
        beforeDeactivation: NSRect,
        visibleFrames: [NSRect],
        minimumShrink: CGFloat = 40,
        minimumOnScreenFraction: CGFloat = 0.75
    ) -> NSRect? {
        // Require a meaningful shrink in at least one dimension. A frame that
        // is the same size or larger than before is left untouched.
        let shrankWidth = beforeDeactivation.width - current.width >= minimumShrink
        let shrankHeight = beforeDeactivation.height - current.height >= minimumShrink
        guard shrankWidth || shrankHeight else { return nil }

        let area = beforeDeactivation.width * beforeDeactivation.height
        guard area > 0 else { return nil }

        // Pick the screen the previous frame overlaps most and require it to be
        // substantially on that screen, so a display topology/resolution change
        // while inactive can't restore a stale frame mostly off-screen.
        var bestVisible: NSRect?
        var bestArea: CGFloat = 0
        for visible in visibleFrames {
            let intersection = beforeDeactivation.intersection(visible)
            let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
            if intersectionArea > bestArea {
                bestArea = intersectionArea
                bestVisible = visible
            }
        }
        guard let target = bestVisible, bestArea >= area * minimumOnScreenFraction else {
            return nil
        }

        // Clamp to that screen so a small overhang past the visible area (e.g.
        // a titlebar that sat under the menu bar) doesn't leave part of the
        // window off-screen after restoring.
        let restored = clampedToVisibleFrame(beforeDeactivation, target)

        // Only restore when the clamped result still meaningfully un-shrinks the
        // window; if clamping collapsed it back to ~the current size, leave it.
        guard restored.width - current.width >= minimumShrink
            || restored.height - current.height >= minimumShrink else {
            return nil
        }
        return restored
    }

    /// Fits `frame` inside `visibleFrame`: shrinks it to the visible size when
    /// larger, then nudges it fully on-screen.
    private nonisolated static func clampedToVisibleFrame(_ frame: NSRect, _ visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Restores `window` to `frameBeforeDeactivation` when
    /// ``restoredFrameAfterInactiveDisplayTransition(current:beforeDeactivation:visibleFrames:minimumShrink:)``
    /// decides the window shrank while the app was inactive. Windows still in
    /// native fullscreen are skipped — macOS owns their frame. Returns whether
    /// a restore was applied.
    @MainActor
    @discardableResult
    static func applyRestoredFrameAfterInactiveDisplayTransition(
        to window: NSWindow,
        frameBeforeDeactivation: NSRect,
        visibleFrames: [NSRect]
    ) -> Bool {
        guard !window.styleMask.contains(.fullScreen) else { return false }
        guard let restored = restoredFrameAfterInactiveDisplayTransition(
            current: window.frame,
            beforeDeactivation: frameBeforeDeactivation,
            visibleFrames: visibleFrames
        ) else { return false }
        window.setFrame(restored, display: true)
        return true
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
