import AppKit
import SwiftUI

/// Hosts onboarding without allowing SwiftUI measurements to resize its AppKit window.
@MainActor
final class ComputerUseOnboardingHostingView: NSHostingView<AnyView> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let window {
            size.width = min(size.width, window.frame.width)
            size.height = min(size.height, window.frame.height)
        }
        super.setFrameSize(size)
    }

    convenience init<Content: View>(rootView: Content) {
        self.init(rootView: AnyView(rootView))
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
        autoresizingMask = [.width, .height]
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
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

    private func animateFrameWithAppKit(
        _ frameRect: NSRect,
        display flag: Bool
    ) {
        super.setFrame(frameRect, display: flag, animate: true)
    }

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

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        appKitOwnedAnimationDuration ?? super.animationResizeTime(newFrame)
    }
}
