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
@MainActor
final class ComputerUseOnboardingWindow: NSWindow {
    private var appKitOwnedSize: NSSize

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
    func setAppKitOwnedFrame(_ frameRect: NSRect, display flag: Bool) {
        appKitOwnedSize = frameRect.size
        super.setFrame(frameRect, display: flag)
    }

    /// Origin-only moves remain available for centering and permission-window
    /// placement. Size changes must go through `setAppKitOwnedFrame` so hosted
    /// SwiftUI measurements cannot feed back into the window during layout.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard frameRect.size != appKitOwnedSize else {
            super.setFrame(frameRect, display: flag)
            return
        }

        super.setFrame(
            NSRect(origin: frame.origin, size: appKitOwnedSize),
            display: flag
        )
    }
}
