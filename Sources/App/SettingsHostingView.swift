import AppKit
import SwiftUI

/// SwiftUI content host whose size follows the native Settings window.
/// `NSHostingView` otherwise observes window layout and may feed a measured
/// content size back into `NSWindow`, creating a recursive sizing loop.
@MainActor
final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    override var fittingSize: NSSize { SettingsWindowPresenter.minimumSize }
    override var intrinsicContentSize: NSSize { SettingsWindowPresenter.minimumSize }

    /// Shadows NSHostingView's private Objective-C window-layout callback, as
    /// cmux's main-window host does. Settings size belongs to AppKit and the
    /// user, never to a SwiftUI content measurement.
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
        // AppKit owns the title and toolbar above. Without this, SwiftUI
        // replaces the native toolbar after the NavigationSplitView renders.
        sceneBridgingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
