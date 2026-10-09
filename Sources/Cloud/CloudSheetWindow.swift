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
    private let initialContentSize: NSSize
    private var isOpening = false
    private var pendingContentSize: NSSize?
    private var isResizeScheduled = false

    init<Content: View>(rootView: Content) {
        // The presenter retains this wrapper while the window is presented;
        // the root view retains the reporter that points back to this owner.
        let reporter = SizeReporter()
        let controller = NSHostingController(rootView: CloudSheetContent(content: rootView, report: reporter))
        controller.sizingOptions = []
        window = NSWindow(contentViewController: controller)
        let initialSize = controller.view.fittingSize
        initialContentSize = Self.rounded(initialSize)
        if initialSize.width > 0, initialSize.height > 0 {
            window.setContentSize(initialContentSize)
        }
        reporter.owner = self
    }

    /// Attaches the sheet to `host`; the size is held until the open
    /// animation has finished.
    func beginSheet(on host: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        isOpening = true
        host.beginSheet(window, completionHandler: completionHandler)
        isOpening = false
        // Some AppKit versions reset a newly attached sheet to a 1×0 content
        // rect while the host is inactive. Restore the measured first layout
        // before applying any later geometry report.
        restoreInitialContentSizeIfNeeded()
        applyPendingContentSize()
        // The reset can happen on the next run-loop turn, after beginSheet
        // returns. Reapply after AppKit has attached the sheet as well.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreInitialContentSizeIfNeeded()
            self.applyPendingContentSize()
        }
    }

    /// Shows the sheet as a centered floating window when no host is on screen.
    func orderFrontFloating() {
        isOpening = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        isOpening = false
        applyPendingContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreInitialContentSizeIfNeeded()
            self.applyPendingContentSize()
        }
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

    private func restoreInitialContentSizeIfNeeded() {
        guard initialContentSize.width > 1, initialContentSize.height > 1 else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard current.width <= 1 || current.height <= 1 else { return }
        window.setContentSize(initialContentSize)
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
            // Sheets in this wrapper all declare a natural width. Measuring
            // horizontally as flexible lets an attached sheet's temporary
            // 1-point proposal collapse the content to 1×0, so later model
            // updates never produce a usable geometry report. Keep both axes
            // intrinsic while the wrapper applies the measured size outside
            // AppKit's layout pass.
            .fixedSize(horizontal: true, vertical: true)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                report.owner?.contentIdealSizeChanged(size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
