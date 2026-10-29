import AppKit

/// The tabs of one host view whose pages Chromium draws in its own Cocoa view inside it
/// (Track B). The fork moves a tab's `WebContentsViewCocoa` into the host view, below its other subviews
/// (`cmux_shim_browser_attach_view`, fork API 36), as Chrome puts a tab's view in its
/// window's content view (`content/browser/web_contents/web_contents_view_mac.mm`). Pixels, input, IME, cursor,
/// drag and accessibility then come from Chromium's view, and the tab's page window never orders in.
///
/// One attach per browser while its view stays in the host view: a tab switch shows that tab's view and hides
/// the others, with no fork call, as Chrome keeps only the active tab's view shown. When a hidden view held the
/// focus, the shown one takes it, as Chrome's tab switch stores and restores focus
/// (`WebContentsViewMac::StoreFocus` / `RestoreFocus`). A refusal keeps the fallback (layer hosting of the page
/// window, else the page window). The first refusal of a browser arms one retry, as a refused hosting request
/// does (the fork refuses a browser not in its page window yet): on the tracker's next read or the tab's next
/// show. A second refusal is final. The views are Chromium's, which removes one when its browser closes, so
/// only weak references are kept.
final class CEFAttachedPages {
    /// `cmux_shim_browser_attach_view`: true when the fork moved `browser`'s view into `parent`, below every
    /// other subview.
    typealias Attach = (_ browser: Int32, _ parent: NSView) -> Bool

    /// What one ``attach(_:with:)`` did.
    nonisolated enum Outcome: Equatable {
        case attached
        /// The first refusal: the one retry waits (``retryArmed``).
        case retryArmed
        /// The second refusal: final.
        case refused
        /// No fork call: already attached here, refused for good, or no host view.
        case unchanged
    }

    private struct Entry {
        weak var view: NSView?
    }

    /// The host view the views are attached in.
    weak var parent: NSView?
    private var entries: [Int32: Entry] = [:]
    /// Browsers the fork refused to attach here twice: they keep the fallback.
    private(set) var refused: Set<Int32> = []
    /// Browsers the fork refused once: their one retry waits for the tracker's next read or their next show.
    private(set) var retryArmed: Set<Int32> = []
    /// The browser the host shows now.
    private(set) var shown: Int32?
    /// Attach calls into the fork so far.
    private(set) var attachCalls = 0

    /// `browser`'s view while it is still in ``parent`` (a tab moved to another pane is attached there).
    func view(of browser: Int32) -> NSView? {
        guard let view = entries[browser]?.view, let parent, view.superview === parent else { return nil }
        return view
    }

    /// The shown browser's view, when it is attached here.
    var shownView: NSView? { shown.flatMap(view(of:)) }

    /// `browser` has no view here and the fork did not refuse it for good: a first attach or the one retry.
    func needsAttach(_ browser: Int32) -> Bool {
        view(of: browser) == nil && !refused.contains(browser)
    }

    /// Asks the fork to attach `browser`'s view in ``parent``: once per browser, twice after a first refusal.
    func attach(_ browser: Int32, with attach: Attach) -> Outcome {
        guard let parent, needsAttach(browser) else { return .unchanged }
        attachCalls += 1
        CEFHostView.trackerStats.pagesAttached += 1
        // The fork puts the tab's view below every other subview of the parent.
        guard attach(browser, parent), let view = parent.subviews.first else {
            CEFHostView.trackerStats.attachRefused += 1
            guard retryArmed.remove(browser) != nil else {
                retryArmed.insert(browser)
                return .retryArmed
            }
            refused.insert(browser)
            return .refused
        }
        retryArmed.remove(browser)
        entries[browser] = Entry(view: view)
        view.isHidden = browser != shown
        layout()
        return .attached
    }

    /// The host shows `browser`: its view shows at the host's size, then every other one here hides. No fork call.
    func show(_ browser: Int32) {
        shown = browser
        let next = view(of: browser)
        if let next, next.isHidden { next.isHidden = false }
        for (id, entry) in entries where id != browser {
            guard let view = entry.view, view.superview === parent, !view.isHidden else { continue }
            hide(view, focusing: next)
        }
        layout()
    }

    /// Sizes the shown view to the host view (`CEFHostView.layout()`).
    func layout() {
        guard let parent, let view = shownView, view.frame != parent.bounds else { return }
        view.frame = parent.bounds
    }

    /// The page window's live browsers are `browsers`: the others closed or left for another pane's window,
    /// so their views, if still here, hide until that pane attaches them.
    func keep(_ browsers: [Int32]) {
        let live = Set(browsers)
        if let shown, !live.contains(shown) { self.shown = nil }
        let next = shownView
        for (id, entry) in entries where !live.contains(id) {
            if let view = entry.view, view.superview === parent, !view.isHidden { hide(view, focusing: next) }
        }
        entries = entries.filter { live.contains($0.key) }
        refused.formIntersection(live)
        retryArmed.formIntersection(live)
    }

    /// The page window closed: Chromium removes its views; nothing is kept.
    func reset() {
        entries = [:]
        refused = []
        retryArmed = []
        shown = nil
    }

    /// Hides `view`. When it holds the window's first responder, `next` (the shown tab's view) takes it, else
    /// the window does; AppKit would give a hidden first responder's focus to an arbitrary next key view.
    private func hide(_ view: NSView, focusing next: NSView?) {
        if let window = view.window, let focused = window.firstResponder as? NSView, focused.isDescendant(of: view) {
            window.makeFirstResponder(next.flatMap(Self.focusTarget(in:)))
        }
        view.isHidden = true
    }

    /// The view that takes the focus in a tab's view: the first one that accepts it, breadth first (Chromium's
    /// `RenderWidgetHostViewCocoa` inside its `WebContentsViewCocoa`).
    private static func focusTarget(in view: NSView) -> NSView? {
        var queue = [view]
        var index = 0
        while index < queue.count {
            let candidate = queue[index]
            if candidate.acceptsFirstResponder { return candidate }
            queue.append(contentsOf: candidate.subviews)
            index += 1
        }
        return nil
    }

    /// The shim's attach call, or nil without it: feature `cefAttachedPages` off, a fork below
    /// ``CEFLayerHosting/attachViewForkAPI`` (its shim still exports the call, which always refuses), host mode.
    static func shimAttach(_ shim: CEFShimLibrary, apiVersion: Int32, enabled: Bool) -> Attach? {
        guard enabled, apiVersion >= CEFLayerHosting.attachViewForkAPI, let attachView = shim.browserAttachView else {
            return nil
        }
        return { browser, parent in attachView(browser, CEFParentView(view: parent)) == 1 }
    }
}
