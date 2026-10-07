import AppKit
import SwiftUI

/// Hosts Settings SwiftUI content without allowing content measurement to
/// resize the AppKit-owned window during its layout pass.
///
/// `NSHostingController` observes its window through the scene bridge. On
/// macOS 27, the Settings ``NavigationSplitView`` could feed its measured
/// size back into the window while `NSWindow(contentViewController:)` was
/// still constructing the view hierarchy. AppKit then re-entered layout until
/// the main-thread stack overflowed. The window owns its fixed initial size;
/// this host reports only the Settings minimum and disables sizing feedback.
@MainActor
final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    override var fittingSize: NSSize { SettingsWindowPresenter.minimumSize }
    override var intrinsicContentSize: NSSize { SettingsWindowPresenter.minimumSize }

    /// Prevents the private AppKit window-layout callback from forwarding
    /// another geometry update into SwiftUI while the window is laying out.
    @objc private func windowDidLayout() {}

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let window {
            let bound = window.frame.size
            if bound.width >= 1, bound.height >= 1 {
                size.width = min(size.width, bound.width)
                size.height = min(size.height, bound.height)
            }
        }
        super.setFrameSize(size)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        sceneBridgingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
