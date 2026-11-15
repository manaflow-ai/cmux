public import AppKit

public extension NSView {
    /// Draws a keystroke's edit in the frame it was made in, in a first-party WebKit page. Call
    /// after `super.keyDown(with:)` in the page's web view, so the update is queued behind the key.
    ///
    /// WebKit starts a page's rendering update only at the display's next refresh: the key reaches
    /// the page, the page edits and renders the composer, and the frame that shows the edit waits
    /// for the next display-link callback (up to a whole refresh interval, 16.7 ms at 60 Hz); then
    /// the commit goes to the window server, which shows it at the refresh after that. Chromium
    /// begins a frame on input at once. This asks WebKit to update the page's rendering now (SPI
    /// `_doAfterNextPresentationUpdate:`, sent on the same connection right behind the key): the
    /// edit is laid out, painted and committed as soon as the page has handled the key, and reaches
    /// the next refresh.
    ///
    /// One message per key down and nothing else: no timer and no loop, so an idle page has no new
    /// wakeups. A WebKit without the selector keeps its own pacing.
    @MainActor
    func renderKeyEditNow() {
        // The WebKit selector that updates a page's rendering now and calls back once it is presented.
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let renderNowSelector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard responds(to: renderNowSelector) else { return }
        typealias Action = @convention(block) () -> Void
        // WebKit keeps the block until the update is presented: it must be an escaping one.
        let presented: Action = {}
        perform(renderNowSelector, with: presented)
    }
}
