#if DEBUG
import AppKit
import SwiftUI

/// Debug-only accessor that reports a popover window after its view has attached.
@MainActor
struct BrowserDownloadsPopoverAppearanceWindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> BrowserDownloadsPopoverAppearanceWindowObservingView {
        let view = BrowserDownloadsPopoverAppearanceWindowObservingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(
        _ nsView: BrowserDownloadsPopoverAppearanceWindowObservingView,
        context: Context
    ) {
        nsView.onWindow = onWindow
        nsView.reportWindowIfAttached()
    }
}
#endif
