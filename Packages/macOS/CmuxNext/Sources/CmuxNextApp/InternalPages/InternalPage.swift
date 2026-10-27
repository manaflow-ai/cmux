import AppKit
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextIcons
import CmuxNextPages

/// Internal pages: cmux's own surfaces (Settings, Debug Settings, the App
/// Store) shown as tabs in a pane instead of windows of their own.
///
/// One mechanism for every page (plans/cmux-next/COORDINATION.md, lane 20):
/// - a session-local tab kind, ids `local-page:<page>:<uuid>`
///   (``LocalPageTab``), kept by ``InternalPageTabStore`` like agent tabs
///   (not restored after relaunch);
/// - a page registers one ``InternalPageProvider`` (`services.pages.register`);
/// - its catalog show action (`openSettings`, `openDebugSettings`,
///   `appStore.show`) calls `services.pages.show(<page>)`, which selects the
///   page's tab in the active window or opens one after the focused pane's
///   selected tab. One tab per page per window.
nonisolated struct InternalPageID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let settings = InternalPageID(rawValue: "settings")
    static let debugSettings = InternalPageID(rawValue: "debug-settings")
}

/// Ids of internal page tabs.
nonisolated enum LocalPageTab {
    static let prefix = "local-page:"

    static func makeKey(_ page: InternalPageID) -> String {
        prefix + page.rawValue + ":" + UUID().uuidString.lowercased()
    }

    /// The page a tab id shows, or nil for another kind of tab.
    static func page(of key: String) -> InternalPageID? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.lastIndex(of: ":"), colon > rest.startIndex else { return nil }
        return InternalPageID(rawValue: String(rest[..<colon]))
    }
}

/// What a page tells the shell. The provider is the page's owner: it keeps
/// the page model (one per app is usual) and makes one view per tab.
@MainActor
protocol InternalPageProvider: AnyObject {
    var page: InternalPageID { get }
    /// The tab title (localized).
    var title: String { get }
    /// SF Symbol of the tab, drawn when `icon` is nil.
    var symbol: String { get }
    /// The tab's cmux icon. Default: nil.
    var icon: IconName? { get }
    /// A new view for the tab `key` (called on the tab's first show, not at its open, and again
    /// after a discard). What the open asked for (a route, a folder) is kept under `key` until then
    /// (``PageOpenRequests``). `window` is the main window the tab is in, for its theme scope.
    func makeView(for key: String, in window: WindowController?) -> NSView
    /// The tab `key` closed: its view is gone.
    func tabClosed(_ key: String)
    /// The title of tab `key`, for a page whose tabs show different things
    /// (a diff tab names its folder). Default: ``title``.
    func title(for key: String) -> String
    /// The page history of tab `key` (``PageHistory``), for a page with
    /// sub-views. Default: none.
    func history(for key: String) -> (any PageHistory)?
    /// What tab `key` shows (a viewer's file or folder), kept as its store
    /// tab's route (`page-tab-route-v1`) so a reopened or relaunched tab
    /// shows it again (reopen-closed.md 3.0). Default: nil.
    func route(for key: String) -> String?
    /// A store tab came back with `route` (Reopen Closed, relaunch): tab
    /// `key` shows it, set up before its first view. The route comes from the
    /// daemon, so a provider treats it like an open it did not choose (an
    /// agent's open). Default: nothing.
    func restore(_ route: String, for key: String)
    /// The title of a store tab known only by its `route` (restored, not yet
    /// shown, so it has no key): nil uses ``title``. Default: nil.
    func title(forRoute route: String) -> String?
    /// A native bar shown above tab `key`'s view (the Markdown omnibar),
    /// asked once right after ``makeView(for:in:)``. Default: none.
    func makeTopBar(for key: String) -> NSView?

    // MARK: Discard (`memoryDiscardInternalPages`, p07-memory.md 3.C)
    //
    // With the feature on, a hidden tab's view goes once its policy says so: the tab keeps its
    // place, title, icon and route (``route(for:)``, given back through ``restore(_:for:)``), and
    // its next show calls ``makeView(for:in:)`` again for the same `key`, then
    // ``restoreViewState(_:for:content:)``. Only a provider that declares a policy is discarded,
    // and it owns the teardown: the store never closes a view it did not make.

    /// When tab `key`'s hidden view may go. Default: ``ContentDiscardPolicy/never``. A provider that
    /// returns another policy implements ``viewDiscarded(_:)`` and keeps no view across a discard.
    func discardPolicy(for key: String) -> ContentDiscardPolicy
    /// Why tab `key`'s view must stay now (an edit not saved, a recording, a request in flight),
    /// first reason first; empty when it may go. Asked right before a discard, and again one
    /// policy time later while it keeps the view. Default: none.
    func keepReasons(for key: String) -> [CannotDiscardReason]
    /// What tab `key` shows besides its route, read right before its view `content` goes.
    /// Default: a page's document scroll (``PageWebView``, either engine), else the position of
    /// the first scroll view in `content`.
    func saveViewState(for key: String, content: NSView) async -> ContentViewState
    /// Puts `state` back on tab `key`'s rebuilt view `content` once it can take it: a page once its
    /// new document painted, native content once it has its size. Its picture covers it until this
    /// returns and the page drew. Default: the scroll ``saveViewState(for:content:)`` read.
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async
    /// Tab `key`'s view is made again after the discard that kept `state` (empty for a discard
    /// nobody prepared): called right before ``makeView(for:in:)``, so a page can take its state in
    /// its first config. Default: nothing.
    func willRemakeView(for key: String, with state: ContentViewState)
    /// Whether tab `key`'s last picture is kept while its view is gone (the rebuilt view's cover
    /// and the tab's hover preview). Default: true; a page that lists secrets says false, so its
    /// listing is not kept as a bitmap.
    func keepsDiscardPicture(for key: String) -> Bool
    /// Tab `key`'s view went and the tab stays: close and drop the view's page, models and holders
    /// (``tabClosed(_:)`` without forgetting the tab's route or file), so the next
    /// ``makeView(for:in:)`` makes a new, live view. Default: nothing (the never policy's).
    func viewDiscarded(_ key: String)
}

extension InternalPageProvider {
    var icon: IconName? { nil }
    func tabClosed(_ key: String) {}
    func title(for key: String) -> String { title }
    func history(for key: String) -> (any PageHistory)? { nil }
    func route(for key: String) -> String? { nil }
    func restore(_ route: String, for key: String) {}
    func title(forRoute route: String) -> String? { nil }
    func makeTopBar(for key: String) -> NSView? { nil }
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .never }
    func keepReasons(for key: String) -> [CannotDiscardReason] { [] }
    func saveViewState(for key: String, content: NSView) async -> ContentViewState {
        if let page = content as? PageWebView { return ContentViewState(scroll: await page.documentScroll()) }
        return ContentViewState(scroll: content.firstScrollView?.documentVisibleRect.origin)
    }
    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) async {
        guard let scroll = state.scroll else { return }
        if let page = content as? PageWebView { return await page.scrollDocument(to: scroll) }
        content.firstScrollView?.restoreScroll(scroll)
    }
    func willRemakeView(for key: String, with state: ContentViewState) {}
    func keepsDiscardPicture(for key: String) -> Bool { true }
    func viewDiscarded(_ key: String) {}
}

extension PageWebView {
    /// The document's scroll (`window.scrollX`, `window.scrollY`), in either engine; nil when the
    /// page does not answer. WebKit scrolls a page in its web process, so no NSScrollView has it.
    func documentScroll() async -> CGPoint? {
        let value = await callPageFunction("return [window.scrollX, window.scrollY];") as? [Any]
        guard let numbers = value?.compactMap({ ($0 as? NSNumber)?.doubleValue }), numbers.count == 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    /// Scrolls the document to `point` and returns once the page ran it.
    func scrollDocument(to point: CGPoint) async {
        guard point.x.isFinite, point.y.isFinite else { return }
        _ = await callPageFunction("window.scrollTo(x, y); return null;", arguments: ["x": Double(point.x), "y": Double(point.y)])
    }
}

extension NSView {
    /// The first scroll view in this view's tree, breadth first (a page's main list or document):
    /// the default view state of a discarded page tab.
    var firstScrollView: NSScrollView? { firstScrollView(where: { _ in true }) }

    /// The first scroll view of a list (`NSTableView`, which a SwiftUI `List` is) in this view's
    /// tree: a native page's rows, past a sidebar or toolbar scroll view before it.
    var listScrollView: NSScrollView? { firstScrollView(where: { $0.documentView is NSTableView }) }

    /// The first scroll view in this view's tree, breadth first, that `matches`.
    func firstScrollView(where matches: (NSScrollView) -> Bool) -> NSScrollView? {
        var queue: [NSView] = [self]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if let scroll = next as? NSScrollView, matches(scroll) { return scroll }
            queue.append(contentsOf: next.subviewsIncludingGated)
        }
        return nil
    }
}

extension NSScrollView {
    /// Scrolls to `origin`, a discarded page's saved scroll; nothing for nil.
    func restoreScroll(_ origin: CGPoint?) {
        guard let origin else { return }
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}
