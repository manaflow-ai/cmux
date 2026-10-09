import AppKit
import SwiftUI

/// A Cloud sheet's window, sized from its SwiftUI content without letting
/// AppKit's layout pass resize it.
///
/// With `sizingOptions = [.preferredContentSize]` the window follows the
/// content from inside AppKit's layout pass: the frame change invalidates the
/// hosting view's safe area, SwiftUI measures again, and any control whose
/// size depends on the width it is offered keeps the cycle going. While
/// `beginSheet` animates, AppKit counts those passes and throws once they
/// outnumber the window's views, which aborts the app. A labeled checkbox and
/// then the Base pop-up each started that cycle in the New Machine sheet, so
/// guarding one control at a time does not hold.
///
/// Here the hosting controller has no sizing options. The content reports its
/// ideal size, and the window takes it with an explicit frame change on a
/// later main-queue turn, after the open animation and never inside a layout
/// pass. A width-sensitive control can no longer feed back into the window,
/// and content that appears later (a loaded plan, an expanded allowlist, an
/// error) still gets room.
@MainActor
final class CloudSheetWindow {
    let window: NSWindow
    private var isOpening = false
    private var pendingContentSize: NSSize?
    private var isResizeScheduled = false

    init<Content: View>(rootView: Content) {
        // The root view retains this object through `report`; the window is
        // weakly reachable from here only through `window`, so no cycle.
        let reporter = SizeReporter()
        let controller = NSHostingController(rootView: CloudSheetContent(content: rootView, report: reporter))
        controller.sizingOptions = []
        window = NSWindow(contentViewController: controller)
        let initialSize = controller.view.fittingSize
        if initialSize.width > 0, initialSize.height > 0 {
            window.setContentSize(Self.rounded(initialSize))
        }
        reporter.owner = self
    }

    /// Attaches the sheet to `host`; the size is held until the open
    /// animation has finished.
    func beginSheet(on host: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        isOpening = true
        host.beginSheet(window, completionHandler: completionHandler)
        isOpening = false
        applyPendingContentSize()
    }

    /// Shows the sheet as a centered floating window when no host is on screen.
    func orderFrontFloating() {
        isOpening = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        isOpening = false
        applyPendingContentSize()
    }

    fileprivate func contentIdealSizeChanged(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        pendingContentSize = Self.rounded(size)
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        // Leave the layout pass that reported the size; apply on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isResizeScheduled = false
            self.applyPendingContentSize()
        }
    }

    private func applyPendingContentSize() {
        guard !isOpening, let size = pendingContentSize else { return }
        pendingContentSize = nil
        let current = window.contentRect(forFrameRect: window.frame).size
        guard size != current else { return }
        // Keep the top edge, where a sheet hangs from its host, and the center.
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = oldFrame.midX - frame.width / 2
        frame.origin.y = oldFrame.maxY - frame.height
        window.setFrame(frame, display: window.isVisible, animate: false)
    }

    private static func rounded(_ size: NSSize) -> NSSize {
        NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    fileprivate final class SizeReporter {
        weak var owner: CloudSheetWindow?
    }
}

/// Lays the content out at its ideal height, pinned to the top, and reports
/// that size. The ideal height does not depend on the window's height, so a
/// resize never changes what is reported. Internal so tests can reach the
/// content's actions through the hosting controller.
struct CloudSheetContent<Content: View>: View {
    let content: Content
    fileprivate let report: CloudSheetWindow.SizeReporter

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                report.owner?.contentIdealSizeChanged(size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
