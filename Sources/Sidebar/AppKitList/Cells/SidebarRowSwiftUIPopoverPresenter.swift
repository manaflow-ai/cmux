import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI

// MARK: - SwiftUI popover presenter

/// Presents existing SwiftUI popover content (`SidebarWorkspaceStatusPopover`,
/// `SidebarWorkspaceChecklistPopover`) from a pure-AppKit row cell. Popovers
/// sit off the scroll path, so hosting SwiftUI here reuses the legacy views
/// wholesale for exact parity instead of reimplementing them in AppKit.
///
/// Follows `SidebarWorkspaceTodoPopoverHost`'s contract:
/// - No `sizingOptions` on the hosting controller; `contentSize` is driven
///   manually from `fittingSize` (clamped to `minWidth`/`maxHeight`).
/// - Each hidden-to-shown transition bumps the SwiftUI view identity so every
///   open gets fresh view-local state.
/// - The popover window is promoted to key on show so embedded fields and
///   keyboard navigation receive input (`PopoverKeyWindowElevator`).
@MainActor
final class SidebarRowSwiftUIPopoverPresenter: NSObject, NSPopoverDelegate {
    var minWidth: CGFloat = 200
    var maxHeight: CGFloat = 480
    /// Called when AppKit closed the popover out from under the container
    /// (transient click-away, app deactivation) — NOT for programmatic
    /// `close()` calls. Containers use this to write presentation state back.
    var onExternalDismiss: (() -> Void)?

    /// Lazy: cells allocate presenters eagerly, but the hosting machinery
    /// only spins up when a popover actually presents (off the scroll path).
    private lazy var hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private(set) var popover: NSPopover?
    private var presentationCount = 0
    private var closingProgrammatically = false
    /// Completes a close whose `popoverDidClose` never arrives; see
    /// `armCloseCompletionFallback(for:)`.
    private let closeCompletionFallback: MainActorDeferredActionScheduler
    /// The popover the pending fallback will complete.
    private weak var closeCompletionFallbackTarget: NSPopover?

    /// How long an animated close may take before the presenter completes
    /// it itself: NSPopover's close fade (about 0.2 s) plus a wide margin
    /// for a busy main thread.
    static let closeCompletionTimeout: Duration = .seconds(1)
    /// Visible refreshes arrive from the table's configure pass (inside a
    /// representable update turn); defer + coalesce them like
    /// `SidebarWorkspaceTodoPopoverHost` does instead of forcing synchronous
    /// hosted-view layout per publisher burst.
    private let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()
    private var pendingRoot: AnyView?

    var isShown: Bool { popover?.isShown == true }

    /// True from `popoverWillClose` until `popoverDidClose`. An animated close
    /// keeps `isShown` true until the animation ends, so containers that
    /// must know whether a close already began check this as well.
    private(set) var isClosing = false

    /// - Parameter closeCompletionClock: Drives the close-completion
    ///   fallback's deadline. Tests pass a clock they advance by hand.
    init(closeCompletionClock: any Clock<Duration> = ContinuousClock()) {
        closeCompletionFallback = MainActorDeferredActionScheduler(clock: closeCompletionClock)
        super.init()
    }

    func present(
        _ root: AnyView,
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard view.window != nil else { return }
        let popover = self.popover ?? makePopover()
        guard !popover.isShown else {
            update(root)
            return
        }
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        // Showing a hidden popover again supersedes any close still in
        // flight for it: its pending fallback must not abandon the popover
        // that is about to be visible.
        closeCompletionFallback.cancel()
        closeCompletionFallbackTarget = nil
        isClosing = false
        closingProgrammatically = false
        presentationCount += 1
        applyRootView(root)
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// Live refresh while shown: mutations reach the row through the normal
    /// configure pass, which forwards the fresh content here so open popovers
    /// repaint instead of showing creation-time state. Deferred + coalesced
    /// outside the current update turn.
    func update(_ root: AnyView) {
        guard isShown else { return }
        pendingRoot = root
        visibleUpdateScheduler.schedule { [weak self] in
            guard let self, self.isShown, let root = self.pendingRoot else { return }
            self.pendingRoot = nil
            self.applyRootView(root)
        }
    }

    /// Called while the anchor is leaving its window. macOS 26 closes a
    /// shown transient popover when that happens, and an animated close only
    /// reaches `popoverDidClose` once the animation completes. On hosts where
    /// the animation never completes (seen on the owned Mac minis), the
    /// container would wait forever to re-present. Closing without animation
    /// makes the detach-induced close finish at once.
    func suppressCloseAnimationForAnchorDetach() {
        guard let popover, popover.isShown, !isClosing else { return }
        popover.animates = false
    }

    /// The popover survived an anchor reparent: animate its later closes again.
    func restoreCloseAnimationAfterAnchorReattach() {
        guard let popover, popover.isShown, !isClosing else { return }
        popover.animates = true
    }

    func close() {
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        guard let popover, popover.isShown else { return }
        closingProgrammatically = true
        popover.performClose(nil)
    }

    private func applyRootView(_ root: AnyView) {
        hostingController.rootView = AnyView(root.id(presentationCount))
        hostingController.view.invalidateIntrinsicContentSize()
        hostingController.view.layoutSubtreeIfNeeded()
        updateContentSize()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func updateContentSize() {
        let fitting = hostingController.view.fittingSize
        guard fitting.width > 0, fitting.height > 0, let popover else { return }
        CmuxPopoverMutation.setContentSize(NSSize(
            width: ceil(max(fitting.width, minWidth)),
            height: ceil(min(fitting.height, maxHeight))
        ), on: popover)
    }

    func popoverDidShow(_ notification: Notification) {
        PopoverKeyWindowElevator.promoteToKeyIfPossible(hostingController.view.window)
    }

    func popoverWillClose(_ notification: Notification) {
        guard isCurrentPopover(notification) else { return }
        isClosing = true
        if let popover {
            armCloseCompletionFallback(for: popover)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // A didClose that lands after `present` showed the same popover again
        // belongs to the superseded close; the popover on screen stays.
        guard isCurrentPopover(notification), popover?.isShown != true else { return }
        finishClose()
    }

    /// A notification from a popover this presenter already gave up on (see
    /// the fallback below) must not tear down the one presented since.
    private func isCurrentPopover(_ notification: Notification) -> Bool {
        guard let sender = notification.object as? NSPopover else { return true }
        return sender === popover
    }

    /// An animated close reaches `popoverDidClose` only when its animation
    /// finishes, and on some owned Mac minis that never happens (#14895).
    /// The popover then stays `isShown` and the presenter stays closing, so
    /// every later toggle closes the stuck popover again instead of showing
    /// a new one, and a click-away is never written back to the container.
    /// If the close hasn't finished within the timeout, finish it here:
    /// detach from the stuck popover, take its window down, and run the same
    /// completion `popoverDidClose` would have.
    ///
    /// A repeated `popoverWillClose` for the same popover keeps the first
    /// deadline, so it cannot keep pushing the completion back.
    private func armCloseCompletionFallback(for closing: NSPopover) {
        if closeCompletionFallback.isScheduled, closeCompletionFallbackTarget === closing {
            return
        }
        closeCompletionFallbackTarget = closing
        closeCompletionFallback.schedule(after: Self.closeCompletionTimeout) { [weak self, weak closing] in
            guard let self, let closing, closing === self.popover, self.isClosing else { return }
            self.abandon(closing)
        }
    }

    private func abandon(_ closing: NSPopover) {
        closing.delegate = nil
        // Only this stuck popover loses its animation; the next one is new.
        closing.animates = false
        let closingWindow = closing.contentViewController?.view.window
        if closing.isShown {
            closing.close()
        }
        closingWindow?.orderOut(nil)
        // The abandoned popover keeps its hosting controller. Should its
        // stalled close ever resume, it must not tear the content view out of
        // the popover presented next, so that one gets its own controller.
        // Swap before `finishClose()`, whose dismissal callback may present.
        let abandonedController = hostingController
        hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        abandonedController.rootView = AnyView(EmptyView())
        finishClose()
    }

    private func finishClose() {
        closeCompletionFallback.cancel()
        closeCompletionFallbackTarget = nil
        isClosing = false
        visibleUpdateScheduler.cancel()
        pendingRoot = nil
        popover = nil
        // Release the hosted content: the root view's action closures capture
        // the presented workspace strongly, and this presenter lives on a
        // pooled table cell — keeping the last root would retain a closed
        // workspace across cell reuse.
        hostingController.rootView = AnyView(EmptyView())
        let external = !closingProgrammatically
        closingProgrammatically = false
        if external {
            onExternalDismiss?()
        }
        onExternalDismiss = nil
    }
}
