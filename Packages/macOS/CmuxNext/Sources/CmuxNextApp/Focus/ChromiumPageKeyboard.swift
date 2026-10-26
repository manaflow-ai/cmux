import AppKit
import CmuxNextBrowser
import CmuxNextFocusUI

/// The keyboard step for a Chromium page (a browser tab, a cmux page or an agent page in Chromium),
/// the same in both backends (`FocusEffectApplier`).
///
/// Nothing else in the window keeps a responder: a terminal or the omnibar's field editor would
/// keep the keys and the caret while Chromium is told its page has focus. The one exception is the
/// page's own host-mode view (`ChromiumHostPageView` with a view input target), which is the page.
/// The page is tracked in `pages`, so focus leaving it blurs it (``ChildPageFocus/blurPage()``):
/// in process CEF's `SetFocus(false)`, in host mode embedder-active 0 (`CEFTab.applyFocus`).
/// Chrome splits a page's focus the same way: the browser focuses the widget and the hosting
/// view's first responder follows (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm).
@MainActor struct ChromiumPageKeyboard {
    let window: NSWindow
    let pages: ChildPageFocus

    /// `page` takes the keys; the page focused before blurs first.
    func focus(_ page: any BrowserTab) {
        if window.firstResponder !== window, !pageHasResponder(page) { window.makeFirstResponder(nil) }
        // One key change (#24913): the old page blurs without this window taking the keys back
        // first; in process the grant moves them straight to the new page window.
        pages.focus(page)
    }

    /// Host mode with a view input target: the page's own view in this window is the responder.
    private func pageHasResponder(_ page: any BrowserTab) -> Bool {
        guard let view = window.firstResponder as? ChromiumHostPageView else { return false }
        return view.isDescendant(of: page.contentView)
    }
}
