import AppKit
import CmuxComputerUseVisuals
import SwiftUI

/// Hosts onboarding without allowing SwiftUI measurements to resize its AppKit window.
@MainActor
final class ComputerUseOnboardingHostingView: NSHostingView<AnyView> {
    /// The visible content rect expressed in this hosting view's flipped space.
    /// A titled full-size-content window still reserves its title bar in
    /// `contentLayoutRect`; the shared geometry value performs the coordinate
    /// conversion instead of relying on a fixed title-bar height.
    override var safeAreaRect: NSRect {
        guard let window else { return super.safeAreaRect }
        return ComputerUseWindowContentGeometry(
            contentBounds: bounds,
            contentLayoutRect: window.contentLayoutRect
        ).visibleContentRect
    }

    /// Derives edge insets from the same measured visible rect used by SwiftUI.
    override var safeAreaInsets: NSEdgeInsets {
        let rect = safeAreaRect
        return NSEdgeInsets(
            top: max(0, rect.minY - bounds.minY),
            left: max(0, rect.minX - bounds.minX),
            bottom: max(0, bounds.maxY - rect.maxY),
            right: max(0, bounds.maxX - rect.maxX)
        )
    }

    /// Prevents SwiftUI's intrinsic measurement from enlarging the fixed window.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let window {
            size.width = min(size.width, window.frame.width)
            size.height = min(size.height, window.frame.height)
        }
        super.setFrameSize(size)
    }

    /// Erases the generic view type while preserving the hosting configuration.
    convenience init<Content: View>(rootView: Content) {
        self.init(rootView: AnyView(rootView))
    }

    /// Initializes a hosting view with AppKit-owned sizing and autoresizing.
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    /// Storyboard construction is not supported for this programmatic window.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Keeps onboarding window geometry subordinate to explicit controller transitions.
///
/// An NSPanel subclass so the borderless permission companion can carry
/// `.nonactivatingPanel`: clicking or dragging the helper tile beside System
/// Settings must never activate cmux, which would raise the main terminal
/// window over the permission pane the user is dragging into.
@MainActor
final class ComputerUseOnboardingWindow: NSPanel {
    private var appKitOwnedSize: NSSize
    private var appKitOwnsAnimatedFrameTransition = false
    private var appKitOwnedAnimationDuration: TimeInterval?

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        appKitOwnedSize = NSWindow.frameRect(
            forContentRect: contentRect,
            styleMask: style
        ).size
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
    }

    /// Applies one of the controller's fixed onboarding frames.
    func setAppKitOwnedFrame(
        _ frameRect: NSRect,
        display flag: Bool,
        animate: Bool = false,
        duration: TimeInterval? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard animate, frameRect != frame else {
            appKitOwnedSize = frameRect.size
            super.setFrame(frameRect, display: flag)
            completion?()
            return
        }

        // NSWindow's native animation repeatedly enters the two-argument
        // `setFrame` override below. Let those controller-owned intermediate
        // frames through, then restore the fixed-size guard at the destination.
        // Updating `appKitOwnedSize` before the animation would make every
        // intermediate size look like an unsolicited SwiftUI resize and turn
        // the glide into a shrink-then-jump.
        withAppKitOwnedFrameTransition(
            to: frameRect,
            duration: duration
        ) {
            animateFrameWithAppKit(frameRect, display: flag)
        }
        completion?()
    }

    /// Allows AppKit's animated intermediate frames through the fixed-size guard.
    /// Runs the sequence of frame updates produced by AppKit while preserving
    /// the fixed-size guard before and after the controller-owned transition.
    /// This small seam also lets tests exercise intermediate frame acceptance
    /// without driving a visible NSWindow inside XCTest's nested event loop.
    func withAppKitOwnedFrameTransition(
        to frameRect: NSRect,
        duration: TimeInterval? = nil,
        updates: () -> Void
    ) {
        appKitOwnsAnimatedFrameTransition = true
        appKitOwnedAnimationDuration = duration
        updates()
        appKitOwnedSize = frameRect.size
        appKitOwnsAnimatedFrameTransition = false
        appKitOwnedAnimationDuration = nil
    }

    /// Starts the native animated frame transition for a controller-owned move.
    private func animateFrameWithAppKit(
        _ frameRect: NSRect,
        display flag: Bool
    ) {
        super.setFrame(frameRect, display: flag, animate: true)
    }

    /// Keeps unsolicited SwiftUI size changes from changing the window frame.
    /// Origin-only moves remain available for centering and permission-window
    /// placement. Size changes must go through `setAppKitOwnedFrame` so hosted
    /// SwiftUI measurements cannot feed back into the window during layout.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if appKitOwnsAnimatedFrameTransition {
            super.setFrame(frameRect, display: flag)
            return
        }

        guard frameRect.size != appKitOwnedSize else {
            super.setFrame(frameRect, display: flag)
            return
        }

        super.setFrame(
            NSRect(origin: frame.origin, size: appKitOwnedSize),
            display: flag
        )
    }

    /// Returns the controller-supplied duration for native frame animations.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        appKitOwnedAnimationDuration ?? super.animationResizeTime(newFrame)
    }
}
