import Foundation

/// A page whose engine can release its content to free memory while the
/// panel stays open, then bring it back from the saved history.
///
/// Browser Memory Saver discards hidden WebKit panels by swapping in a blank
/// web view. A page of another engine adopts this protocol instead: the panel
/// keeps the page object and its view, the engine closes the renderer, and
/// ``restoreContent()`` (or a load, reload or history step) recreates it with
/// the same back/forward history. Showing the view alone does not, so the
/// panel can wait for the person to ask.
///
/// ```swift
/// if let page = panel.enginePage as? any BrowserPageMemoryReclaiming,
///    page.releaseContent() {
///     discardManager.markDiscarded(reason: reason, now: now)
/// }
/// ```
@MainActor
public protocol BrowserPageMemoryReclaiming: AnyObject {
    /// The process rendering the page's main frame, or `nil` while none is
    /// live. The memory budget counts a process once even when several pages
    /// share it, and frees it only when every page using it is released.
    var contentProcessIdentifier: Int? { get }
    /// `true` from ``releaseContent()`` until the content is recreated.
    var isContentReleased: Bool { get }
    /// The panel's busy-probe bookkeeping, kept with the page.
    var reclaimProbe: BrowserPageReclaimProbe { get set }
    /// Closes the page's renderer, keeping its URL, title and history.
    /// - Returns: `false` when there is nothing to release or the history
    ///   cannot be saved now; the page is then unchanged.
    func releaseContent() -> Bool
    /// Recreates released content from the saved history. Does nothing
    /// unless the content was released.
    func restoreContent()
}
