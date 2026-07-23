import AppKit
import SwiftUI

/// Hosts onboarding without allowing SwiftUI measurements to resize its AppKit window.
@MainActor
final class ComputerUseOnboardingHostingView: NSHostingView<AnyView> {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }

    /// `NSHostingView` otherwise asks its window to follow measured SwiftUI content
    /// from this private AppKit callback. Onboarding has explicit window sizes, so
    /// that feedback can recurse until AppKit terminates the process.
    @objc private func windowDidLayout() {
        // Window size belongs to ComputerUseOnboardingWindowController.
    }

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
