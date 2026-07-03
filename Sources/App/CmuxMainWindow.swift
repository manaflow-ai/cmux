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

/// Shared geometry for deciding whether a window's titlebar band is usably
/// reachable on some screen. Because cmux main windows set `isMovable = false`,
/// the only way a user can move one is the drag handle living in the top
/// titlebar band — so "reachable" is a property of the window's *top strip*,
/// not of the frame as a whole. This is the single reachability definition
/// shared by the constrain-pass veto in `CmuxMainWindow.constrainFrameRect`
/// and the display-topology-change rescue in `MainWindowScreenChangeRescue`,
/// mirroring the top-strip test session restore already applies
/// (`AppDelegate.shouldPreserveAccessibleFrame`).
enum WindowTitlebarReachability {
    struct Thresholds {
        /// Height of the top-of-window strip that is inspected.
        let topStripHeight: CGFloat
        /// Minimum visible width of that strip (or the full window width when
        /// the window is narrower).
        let minimumVisibleWidth: CGFloat
        /// Minimum visible height of that strip (or the full strip height when
        /// the strip is shorter).
        let minimumVisibleHeight: CGFloat

        /// The constrain-pass veto's thresholds: a 64pt strip (the band
        /// session restore's `AppDelegate.shouldPreserveAccessibleFrame` also
        /// inspects) with at least 60x24pt visible. The 60pt width floor
        /// intentionally retains the historical veto tolerance (the pre-2026-07
        /// rule accepted any 60x60pt overlap), so a window deliberately parked
        /// with only 60-119pt of titlebar showing keeps its anti-creep
        /// protection across sleep/wake — as does a titlebar tucked under the
        /// menu bar (>=24pt of the strip stays visible below the bar).
        static let constrainVeto = Thresholds(
            topStripHeight: 64,
            minimumVisibleWidth: 60,
            minimumVisibleHeight: 24
        )

        /// The drag-band thresholds used by the display-change rescue: the
        /// strip is the actual drag-handle band
        /// (`WindowChromeMetrics.sharedChromeBarHeight`), and at least
        /// 120x20pt of it must be visible — enough band to actually grab. A
        /// band fully covered by the menu bar fails this, which is exactly the
        /// case the rescue exists to fix.
        static let strict = Thresholds(
            topStripHeight: WindowChromeMetrics.sharedChromeBarHeight,
            minimumVisibleWidth: 120,
            minimumVisibleHeight: 20
        )
    }

    /// Whether the top strip of `frame` is usably visible on at least one of
    /// `visibleFrames`. Pure and screen-agnostic so tests run deterministically
    /// on CI regardless of the host's display configuration.
    nonisolated static func isTopStripReachable(
        _ frame: CGRect,
        onAnyOf visibleFrames: [CGRect],
        thresholds: Thresholds
    ) -> Bool {
        let standardized = frame.standardized
        guard standardized.width.isFinite,
              standardized.height.isFinite,
              standardized.width > 0,
              standardized.height > 0 else {
            return false
        }

        let stripHeight = min(thresholds.topStripHeight, standardized.height)
        let topStrip = CGRect(
            x: standardized.minX,
            y: standardized.maxY - stripHeight,
            width: standardized.width,
            height: stripHeight
        )
        let requiredWidth = min(thresholds.minimumVisibleWidth, standardized.width)
        let requiredHeight = min(thresholds.minimumVisibleHeight, stripHeight)

        for visibleFrame in visibleFrames {
            let visibleStrip = topStrip.intersection(visibleFrame)
            guard !visibleStrip.isNull else { continue }
            if visibleStrip.width >= requiredWidth, visibleStrip.height >= requiredHeight {
                return true
            }
        }
        return false
    }
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
    /// Fix: refuse the re-constrain for any frame whose titlebar strip is still
    /// reachable on some screen, and defer to AppKit's default only when the
    /// titlebar would otherwise be stranded (e.g. a display was disconnected),
    /// so a genuinely lost window can still be pulled back into view. The
    /// reachability test is titlebar-specific on purpose: cmux main windows set
    /// `isMovable = false`, so a frame whose *body* overlaps a screen but whose
    /// titlebar sits above every screen top is unmovable by the user and must
    /// not be preserved (the pre-titlebar-aware rule accepted any 60x60pt
    /// overlap anywhere in the frame, which is exactly how monitor disconnects
    /// stranded windows).
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
    /// AppKit's constraining pass should be skipped. The frame qualifies when
    /// enough of its titlebar strip is visible on some screen per the
    /// `constrainVeto` thresholds — generous enough to keep preserving a
    /// titlebar tucked under the menu bar or a window parked mostly off a side
    /// edge (the sleep/wake anti-creep behavior), strict enough to let AppKit
    /// rescue a titlebar stranded above every screen.
    nonisolated static func shouldPreserveFrameDuringConstrain(
        _ proposedFrame: NSRect,
        visibleFrames: [NSRect]
    ) -> Bool {
        WindowTitlebarReachability.isTopStripReachable(
            proposedFrame,
            onAnyOf: visibleFrames,
            thresholds: .constrainVeto
        )
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
