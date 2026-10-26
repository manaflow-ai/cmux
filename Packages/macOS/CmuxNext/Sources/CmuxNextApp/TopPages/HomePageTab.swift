import AppKit
import CmuxNextHibernation
import CmuxNextHome
import CmuxNextHomeEngine

extension InternalPageID {
    /// The native Home as a pane tab (`home.tab`). Its own id: the Home top
    /// page is a `TopPageRoute`, never a page tab.
    static let homeTab = InternalPageID(rawValue: "home-tab")
}

/// The native Home (MessagesLab's list and transcript, `TopHomePageView`)
/// as an internal page tab, so it sits in a split next to any other tab, the
/// channels Home among them. Every tab reads the one `HomeService`
/// (`services.home`): a message sent in one Home shows in every other Home
/// at once. Each `home.tab` run opens one more tab; each tab has its own
/// list selection, composer draft and width. The Home top page
/// (`home.show`) stays as it is.
@MainActor
final class HomePageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var views: [String: TopHomePageView] = [:]
    /// The order the tabs opened in (`debug.home` lists them so).
    private var order: [String] = []
    /// The saved list width every Home tab shares (`HomeSidebarWidth` keeps
    /// one width per key; one key per tab would grow without bound).
    static let widthKey = "home-tab"

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .homeTab }
    var title: String { HomeStrings.title }
    var symbol: String { "house" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let view = TopHomePageView(services: services, windowKey: { Self.widthKey })
        views[key] = view
        // A view made again after a discard keeps its tab's place.
        if !order.contains(key) { order.append(key) }
        return view
    }

    func tabClosed(_ key: String) {
        views[key] = nil
        saved[key] = nil
        order.removeAll { $0 == key }
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// What each tab whose view was discarded showed, given to its next view.
    private var saved: [String: TopHomePageView.ViewState] = [:]

    /// Ten minutes hidden: conversations, their drafts and scroll live in Home's store, and the
    /// rest of what the tab shows is its view state.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// The tab stays: its shown conversation and New Message draft wait for its next view.
    func viewDiscarded(_ key: String) {
        guard let view = views.removeValue(forKey: key) else { return }
        saved[key] = view.viewState
    }

    func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
        guard let view = content as? TopHomePageView, let state = saved.removeValue(forKey: key) else { return }
        view.restore(state)
    }

    /// Open Home tabs by provider key, in the order they opened.
    var tabs: [(key: String, view: TopHomePageView)] {
        order.compactMap { key in views[key].map { (key, $0) } }
    }

    /// The transcript a Home tab shows (its conversation's native view).
    static func transcript(in view: NSView) -> HomeNativeTranscriptView? {
        var stack = [view]
        while let next = stack.popLast() {
            if let home = next as? HomeNativeTranscriptView { return home }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// `home.tab`: one more Home tab in the active window, after the focused
    /// pane's selected tab. A user run selects and focuses it (and leaves a
    /// top page); automation opens it without changing the view. False when
    /// the window has no pane to hold it.
    @discardableResult
    static func open(_ services: AppServices, focus: Bool) -> Bool {
        if services.pages.provider(.homeTab) == nil { services.pages.register(HomePageTab(services: services)) }
        return services.pages.openNew(.homeTab, in: services.windows.active, focus: focus) != nil
    }
}
