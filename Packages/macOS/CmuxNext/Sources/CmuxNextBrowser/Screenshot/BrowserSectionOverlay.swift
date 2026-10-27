public import AppKit
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The drag-to-select overlay of Screenshot Section: a borderless panel over
/// a page view (above an engine's child window too) that dims the page,
/// draws the dragged rect, and answers the selection when the mouse goes up.
///
/// Esc, a click without a drag, or the panel losing key status cancels. One
/// overlay runs ``select()`` once.
///
/// ```swift
/// let overlay = BrowserSectionOverlay(over: tab.contentView)
/// guard let selection = await overlay.select() else { return }
/// let section = try await selection.capture(from: tab)
/// ```
public final class BrowserSectionOverlay: NSObject, NSWindowDelegate {
    private let pageView: NSView
    private let pointerFrames: FrameInputCoalescers?
    private var panel: NSPanel?
    private var continuation: OnceContinuation<BrowserSectionSelection?, OnceContinuationError>?
    private var started = false

    /// An overlay for `pageView` (a ``BrowserTab``'s `contentView`).
    /// - Parameters:
    ///   - pageView: The view the page draws in, or the placeholder
    ///     a child-window engine tracks.
    ///   - pointerFrames: The windows' frame-aligned pointer input (feature
    ///     `pointerFrameDrags`): the drag's rect moves at most twice a frame. Nil:
    ///     on every drag event.
    public init(over pageView: NSView, pointerFrames: FrameInputCoalescers? = nil) {
        self.pageView = pageView
        self.pointerFrames = pointerFrames
    }

    /// Shows the overlay and waits for the person's drag.
    /// - Returns: The selection over the page view's bounds, or nil when
    ///   cancelled or when the page view is not in a window.
    public func select() async -> BrowserSectionSelection? {
        guard !started, let window = pageView.window else { return nil }
        started = true
        let frame = window.convertToScreen(pageView.convert(pageView.bounds, to: nil))
        // An overlay dropped without an answer (abandoned) cancelled: nil.
        return try? await withOnceContinuation { (continuation: OnceContinuation<BrowserSectionSelection?, OnceContinuationError>) in
            self.continuation = continuation
            let panel = BrowserSectionOverlayPanel(frame: frame)
            let view = BrowserSectionOverlayView(size: frame.size, pointerFrames: self.pointerFrames)
            view.onFinish = { [weak self] selection in self?.finish(selection) }
            panel.contentView = view
            panel.delegate = self
            window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            self.panel = panel
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ selection: BrowserSectionSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        if let panel {
            panel.delegate = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
        continuation.resume(returning: selection)
    }
}
