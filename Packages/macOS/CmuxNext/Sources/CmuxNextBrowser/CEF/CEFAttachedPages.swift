import AppKit

/// The tabs of one host view whose pages Chromium draws in its own Cocoa view inside it (p03-rendering-045,
/// Track B). The fork makes a tab's `RenderWidgetHostViewCocoa` a subview of the host view
/// (`cmux_shim_browser_attach_view`, p03-rendering-044), as Chrome puts a tab's view in its window's content
/// view (`content/browser/web_contents/web_contents_view_mac.mm`). Pixels, input, IME, cursor, drag and
/// accessibility then come from Chromium's view, and the tab's page window never orders in.
///
/// One attach per browser while its view stays in the host view: a tab switch shows that tab's view and hides
/// the others, with no fork call, as Chrome keeps only the active tab's view shown. A browser the fork refused
/// keeps the fallback (layer hosting of its page window, else the page window) and is not asked again. The
/// views are Chromium's, which removes one when its browser closes, so only weak references are kept.
final class CEFAttachedPages {
    /// `cmux_shim_browser_attach_view`: `browser`'s view, added below every other subview of `parent`; nil
    /// when refused.
    typealias Attach = (_ browser: Int32, _ parent: NSView) -> NSView?

    /// What one ``attach(_:with:)`` did.
    nonisolated enum Outcome: Equatable {
        case attached
        case refused
        /// No fork call: already attached here, refused before, or no host view.
        case unchanged
    }

    private struct Entry {
        weak var view: NSView?
    }

    /// The host view the views are attached in.
    weak var parent: NSView?
    private var entries: [Int32: Entry] = [:]
    /// Browsers the fork refused to attach here.
    private(set) var refused: Set<Int32> = []
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

    /// `browser` has no view here and the fork did not refuse it.
    func needsAttach(_ browser: Int32) -> Bool {
        view(of: browser) == nil && !refused.contains(browser)
    }

    /// Asks the fork to attach `browser`'s view in ``parent``, once per browser.
    func attach(_ browser: Int32, with attach: Attach) -> Outcome {
        guard let parent, needsAttach(browser) else { return .unchanged }
        attachCalls += 1
        CEFHostView.trackerStats.pagesAttached += 1
        guard let view = attach(browser, parent), view.superview === parent else {
            refused.insert(browser)
            CEFHostView.trackerStats.attachRefused += 1
            return .refused
        }
        entries[browser] = Entry(view: view)
        view.isHidden = browser != shown
        layout()
        return .attached
    }

    /// The host shows `browser`: its view shows at the host's size and every other one here hides. No fork call.
    func show(_ browser: Int32) {
        shown = browser
        for (id, entry) in entries {
            guard let view = entry.view, view.superview === parent, view.isHidden != (id != browser) else { continue }
            view.isHidden = id != browser
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
        for (id, entry) in entries where !live.contains(id) {
            if let view = entry.view, view.superview === parent { view.isHidden = true }
        }
        entries = entries.filter { live.contains($0.key) }
        refused.formIntersection(live)
        if let shown, !live.contains(shown) { self.shown = nil }
    }

    /// The page window closed: Chromium removes its views; nothing is kept.
    func reset() {
        entries = [:]
        refused = []
        shown = nil
    }

    /// The shim's attach call, or nil without it (feature `cefAttachedPages` off, an older fork, host mode).
    static func shimAttach(_ shim: CEFShimLibrary, enabled: Bool) -> Attach? {
        guard enabled, let attachView = shim.browserAttachView else { return nil }
        return { browser, parent in
            attachView(browser, Unmanaged.passUnretained(parent).toOpaque())
                .map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
        }
    }
}
