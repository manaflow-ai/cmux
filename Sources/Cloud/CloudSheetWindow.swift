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
    // AppKit may expand an attached sheet from its bottom edge before the
    // deferred geometry callback runs. Keep the first stable top edge so a
    // content-driven resize cannot inherit that temporary shift.
    private var topEdgeAnchor: CGFloat?
    // Registration is main-actor-only; deinit only removes these opaque
    // Foundation tokens through NotificationCenter's thread-safe cleanup API.
    nonisolated(unsafe) private var windowMoveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var hostMoveObserver: NSObjectProtocol?
    private weak var hostWindow: NSWindow?
    private var lastHostOrigin: NSPoint?
    private var isAttachedToHost = false
    private var isHostMovePending = false
    private var isHostAnchorRefreshScheduled = false
    private var isAnchorCorrectionScheduled = false
    private var isApplyingFrame = false

    init<Content: View>(rootView: Content) {
        // The presenter retains this wrapper while the window is presented;
        // the root view retains the reporter that points back to this owner.
        let reporter = SizeReporter()
        let controller = NSHostingController(rootView: CloudSheetContent(content: rootView, report: reporter))
        controller.sizingOptions = []
        window = NSWindow(contentViewController: controller)
        // NSHostingController's flexible root view can report its temporary
        // attached-sheet proposal (1×0). Measure an unattached hosting view so
        // the first window frame is based on the content's intrinsic size.
        let initialSize = NSHostingView(
            rootView: CloudSheetContent(content: rootView, report: reporter)
        ).fittingSize
        initialContentSize = Self.rounded(initialSize)
        if initialSize.width > 0, initialSize.height > 0 {
            window.setContentSize(initialContentSize)
        }
        reporter.owner = self
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isAttachedToHost {
                    let didRefreshHostAnchor = self.recordAttachedSheetMoveIfHostMoveIsPending()
                    if didRefreshHostAnchor {
                        // A host move can arrive while AppKit still exposes a
                        // transient 1×0 sheet. The later sheet move completes
                        // the handshake; apply any content size that arrived
                        // while resizing was blocked.
                        self.applyPendingContentSize()
                    }
                    self.scheduleAttachedSheetAnchorCorrection()
                } else {
                    self.recordFloatingWindowMoveIfStable()
                }
            }
        }
    }

    deinit {
        if let windowMoveObserver {
            NotificationCenter.default.removeObserver(windowMoveObserver)
        }
        if let hostMoveObserver {
            NotificationCenter.default.removeObserver(hostMoveObserver)
        }
    }

    /// Attaches the sheet to `host`; the size is held until the open
    /// animation has finished.
    func beginSheet(on host: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        hostWindow = host
        lastHostOrigin = host.frame.origin
        isAttachedToHost = true
        isHostMovePending = false
        hostMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: host,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordHostMoveIfStable(host)
            }
        }
        isOpening = true
        host.beginSheet(window, completionHandler: completionHandler)
        isOpening = false
        // Some AppKit versions reset a newly attached sheet to a 1×0 content
        // rect while the host is inactive. Restore the measured first layout
        // before applying any later geometry report.
        restoreInitialContentSizeIfNeeded()
        applyPendingContentSize()
        // AppKit may perform one more sheet-host layout on the next turn and
        // reset the frame after beginSheet returns. Reapply after that pass so
        // the first geometry report has a usable window to measure against.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreInitialContentSizeIfNeeded()
            self.topEdgeAnchor = self.topEdgeAnchor ?? self.window.frame.maxY
            self.applyPendingContentSize()
        }
    }

    /// Shows the sheet as a centered floating window when no host is on screen.
    func orderFrontFloating() {
        hostWindow = nil
        lastHostOrigin = nil
        isAttachedToHost = false
        isOpening = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        isOpening = false
        topEdgeAnchor = window.frame.maxY
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
        guard !isOpening, !isHostMovePending, let size = pendingContentSize else { return }
        pendingContentSize = nil
        let current = window.contentRect(forFrameRect: window.frame).size
        guard size != current else { return }
        // Keep the top edge, where a sheet hangs from its host, and the center.
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = oldFrame.midX - frame.width / 2
        frame.origin.y = (topEdgeAnchor ?? oldFrame.maxY) - frame.height
        setFrameInternally(frame)
        scheduleAttachedSheetAnchorCorrection()
    }

    private func restoreInitialContentSizeIfNeeded() {
        guard initialContentSize.width > 1, initialContentSize.height > 1 else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard current.width <= 1 || current.height <= 1 else { return }

        // An attached sheet hangs from its top edge. setContentSize preserves
        // the bottom-left origin, which detaches the sheet from its host when
        // repairing AppKit's temporary 1×0 frame. Restore through a frame so
        // the top edge remains anchored while the content gets its size back.
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: initialContentSize))
        frame.origin.x = oldFrame.midX - frame.width / 2
        frame.origin.y = (topEdgeAnchor ?? oldFrame.maxY) - frame.height
        setFrameInternally(frame)
    }

    private func setFrameInternally(_ frame: NSRect) {
        isApplyingFrame = true
        window.setFrame(frame, display: window.isVisible, animate: false)
        isApplyingFrame = false
    }

    private func scheduleAttachedSheetAnchorCorrection() {
        guard isAttachedToHost, topEdgeAnchor != nil, !isAnchorCorrectionScheduled else { return }
        isAnchorCorrectionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAnchorCorrectionScheduled = false
            guard self.isAttachedToHost, !self.isOpening, !self.isApplyingFrame,
                  let anchor = self.topEdgeAnchor else { return }
            let delta = anchor - self.window.frame.maxY
            guard abs(delta) > 0.5 else { return }
            var frame = self.window.frame
            frame.origin.y += delta
            self.setFrameInternally(frame)
        }
    }

    private func recordFloatingWindowMoveIfStable() {
        // An attached sheet's frame can emit didMove after AppKit resizes it
        // from the bottom edge. That is an internal layout move, not a new
        // anchor; only floating windows can be moved directly by the user.
        guard !isAttachedToHost else { return }
        recordStableTopEdge()
    }

    private func recordHostMoveIfStable(_ host: NSWindow) {
        guard isAttachedToHost, hostWindow === host else { return }
        guard !isOpening, !isApplyingFrame else { return }
        guard host.frame.origin != lastHostOrigin else { return }
        lastHostOrigin = host.frame.origin
        isHostMovePending = true
        scheduleHostAnchorRefresh()
    }

    @discardableResult
    private func recordAttachedSheetMoveIfHostMoveIsPending() -> Bool {
        guard isHostMovePending else { return false }
        guard !isOpening, !isApplyingFrame else { return false }
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        guard contentSize.width > 1, contentSize.height > 1 else { return false }
        topEdgeAnchor = window.frame.maxY
        isHostMovePending = false
        return true
    }

    private func scheduleHostAnchorRefresh() {
        guard !isHostAnchorRefreshScheduled else { return }
        isHostAnchorRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHostAnchorRefreshScheduled = false
            guard self.isAttachedToHost, !self.isOpening, !self.isApplyingFrame else { return }
            self.recordAttachedSheetMoveIfHostMoveIsPending()
            self.applyPendingContentSize()
        }
    }

    private func recordStableTopEdge() {
        guard !isOpening, !isApplyingFrame else { return }
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        // During attachment AppKit can briefly publish a 1×0 frame and move
        // its bottom edge. It is not a user move and must not replace the
        // stable anchor used to restore the initial content size.
        guard contentSize.width > 1, contentSize.height > 1 else { return }
        topEdgeAnchor = window.frame.maxY
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
    }
}
