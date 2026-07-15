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

    /// The window must never be resized to fit this view's SwiftUI content.
    /// NSHostingView watches window layout and calls NSWindow.setFrame itself
    /// (`windowDidLayout` → `updateAnimatedWindowSize`) when the content's
    /// measured size disagrees with the window's — and it does so even with
    /// empty `sizingOptions`, which only governs the constraint-based paths.
    /// If content ever measures wider than the window (a workspace pushed
    /// below its minimum width by a programmatic resize), that hook re-grows
    /// the window a step per layout pass, without bound. Shadowing the
    /// hook's Objective-C selector severs the path; should a future macOS
    /// rename it, this no-op stops shadowing anything and
    /// `MainWindowSelfSizingTests` flags the behavior's return.
    @objc private func windowDidLayout() {
        // Deliberately empty: the main window's size belongs to the user and
        // to explicit window management, never to content measurement.
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Belt with the suspenders above: keep the hosting view from creating
        // any content-derived sizing constraints either.
        sizingOptions = []
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

    /// No content may resize this window past the attached display union. The content view
    /// hosts AppKit subtrees whose subviews carry REQUIRED autoresizing-mask
    /// constraints, and if any of them is ever laid out oversized, AppKit
    /// satisfies those constraints by growing the WINDOW — and since this
    /// window is non-movable, nothing ever constrains it back. A layout bug
    /// then compounds through everything derived from window geometry
    /// (observed live: the window at 29,000 points wide, growing every
    /// pass). The user sizes this window; layout does not.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let frame = styleMask.contains(.fullScreen)
            ? frameRect
            : Self.frameByCappingOversizedDimensions(
                frameRect,
                displayFrames: NSScreen.screens.map {
                    (frame: $0.frame, visibleFrame: $0.visibleFrame)
                }
            )
        super.setFrame(frame, display: flag)
    }

    /// Caps runaway content-derived dimensions to the display union while
    /// keeping a previously intersecting window's titlebar reachable. Frames
    /// that already fit are returned byte-for-byte so ordinary partial
    /// off-screen and multi-display placement remains user-owned.
    nonisolated static func frameByCappingOversizedDimensions(
        _ proposedFrame: NSRect,
        displayFrames: [(frame: NSRect, visibleFrame: NSRect)]
    ) -> NSRect {
        let displays = displayFrames.filter { $0.frame.width > 1 && $0.frame.height > 1 }
        let displayUnion = displays.reduce(NSRect.null) { $0.union($1.frame) }
        guard !displayUnion.isNull else { return proposedFrame }

        var capped = proposedFrame
        capped.size.width = min(capped.width, displayUnion.width)
        capped.size.height = min(capped.height, displayUnion.height)
        guard capped.size != proposedFrame.size else { return proposedFrame }

        let target = displays.max { lhs, rhs in
            let left = proposedFrame.intersection(lhs.frame)
            let right = proposedFrame.intersection(rhs.frame)
            return left.width * left.height < right.width * right.height
        }
        guard let target,
              !proposedFrame.intersection(target.frame).isNull,
              !isTitlebarReachable(frame: capped, visibleFrame: target.visibleFrame)
        else { return capped }

        let visibleWidth = min(60, capped.width)
        capped.origin.x = min(
            max(capped.minX, target.visibleFrame.minX - capped.width + visibleWidth),
            target.visibleFrame.maxX - visibleWidth
        )
        let stripHeight = min(64, capped.height)
        let visibleHeight = min(16, stripHeight)
        let clampedMaxY = min(
            max(capped.maxY, target.visibleFrame.minY + visibleHeight),
            target.visibleFrame.maxY + stripHeight - visibleHeight
        )
        capped.origin.y = clampedMaxY - capped.height
        return capped
    }

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

    /// cmux creates its main window programmatically (never from a nib), so it
    /// cannot inherit fullscreen capability from Interface Builder and instead
    /// relied on AppKit *implicitly* granting `.fullScreenPrimary` to a
    /// resizable, titled window. That implicit grant is not reliable across
    /// macOS versions / display arrangements: on macOS 26 (Tahoe) a
    /// freshly-created window reports an empty collection behavior
    /// (`rawValue == 0`) and AppKit does not treat it as fullscreen-capable, so
    /// Toggle Full Screen / ⌃⌘F / the green traffic-light button all fail to
    /// enter a native fullscreen Space — the green button only zooms (#5933).
    ///
    /// Declaring `.fullScreenPrimary` here makes native fullscreen reachable
    /// regardless of the OS's implicit default. It is idempotent where AppKit
    /// would have granted it anyway, and composes with the temporary
    /// `.fullScreenDisallowsTiling` opt-out the window factory applies when
    /// spawning a window out of an existing fullscreen Space.
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        collectionBehavior = Self.canonicalCollectionBehavior(collectionBehavior)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Returns `base` guaranteed to carry `.fullScreenPrimary` (and never
    /// `.fullScreenNone`) so a cmux main window can always enter a native
    /// fullscreen Space. Pure and `nonisolated` so it can be unit-tested
    /// without constructing a window; see ``init(contentRect:styleMask:backing:defer:)``
    /// for why declaring the capability explicitly is required.
    nonisolated static func canonicalCollectionBehavior(
        _ base: NSWindow.CollectionBehavior
    ) -> NSWindow.CollectionBehavior {
        var behavior = base
        // `.fullScreenNone` and `.fullScreenPrimary` are mutually exclusive;
        // drop any stale "none" before declaring primary so fullscreen is not
        // suppressed.
        behavior.remove(.fullScreenNone)
        behavior.insert(.fullScreenPrimary)
        return behavior
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
    /// Delegates to the shared ``isTitlebarReachable(frame:visibleFrame:)``
    /// predicate, which the startup/restore-path clamp
    /// (`AppDelegate.shouldPreserveAccessibleFrame`) also uses, so the runtime
    /// constrain pass and the restore-time clamp can never disagree on what
    /// counts as reachable.
    nonisolated static func shouldPreserveFrameDuringConstrain(
        _ proposedFrame: NSRect,
        visibleFrames: [NSRect]
    ) -> Bool {
        visibleFrames.contains { isTitlebarReachable(frame: proposedFrame, visibleFrame: $0) }
    }

    /// Whether a grabbable slice of `frame`'s titlebar — its top strip — is
    /// visible on `visibleFrame`. This is the single source of truth for "can
    /// the user still grab this window", shared by the runtime constrain veto
    /// (``shouldPreserveFrameDuringConstrain``) and the reactive/restore-time
    /// clamp (`AppDelegate`).
    ///
    /// The window is non-movable (``configureCmuxMainWindowDragBehavior`` sets
    /// `isMovable = false`) and can only be dragged by ``WindowDragHandleView``
    /// in the titlebar band, so a window whose titlebar is off-screen cannot be
    /// recovered even when its body still overlaps a display. Requiring the top
    /// strip to remain reachable lets a stranded window be re-clamped while a
    /// genuinely on-screen frame is left untouched (which is what stops the
    /// sleep/wake drift, #6305).
    ///
    /// The thresholds are deliberately lenient so legitimately-placed windows are
    /// never re-clamped: only ``minimumVisibleWidth`` (60pt) of the titlebar need
    /// remain grabbable, and only ``minimumVisibleHeight`` (16pt) of the strip
    /// need clear the display's top inset — small enough that a window flush to
    /// the top of a large-menu-bar / notch display still qualifies, while a
    /// window whose titlebar is entirely above/off the screen does not.
    nonisolated static func isTitlebarReachable(
        frame: NSRect,
        visibleFrame: NSRect,
        stripHeight: CGFloat = 64,
        minimumVisibleWidth: CGFloat = 60,
        minimumVisibleHeight: CGFloat = 16
    ) -> Bool {
        let frame = frame.standardized
        guard frame.width > 0, frame.height > 0 else { return false }

        let stripHeight = min(stripHeight, frame.height)
        let topStrip = NSRect(
            x: frame.minX,
            y: frame.maxY - stripHeight,
            width: frame.width,
            height: stripHeight
        )
        let intersection = topStrip.intersection(visibleFrame)
        return intersection.width >= min(minimumVisibleWidth, frame.width)
            && intersection.height >= min(minimumVisibleHeight, stripHeight)
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
