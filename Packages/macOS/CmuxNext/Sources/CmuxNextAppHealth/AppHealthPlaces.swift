public import CmuxNextControl
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextPages

/// Resolves a health part's id to where it is on screen (``AppHealthPlace``): the App's answer for the page parts
/// (`page:<n>`, `renderer:<n>`), nil for the parts that have no place (the session service, the page server).
@MainActor
public struct AppHealthPlaces {
    private let place: @MainActor (String) -> AppHealthPlace?

    /// - Parameter place: The place of a part id, nil when it has none (tests pass a fixed table).
    public init(_ place: @escaping @MainActor (String) -> AppHealthPlace?) {
        self.place = place
    }

    /// The places of page parts, from the page view each id names (the App's pane lookup).
    public init(pages: @escaping @MainActor (PageWebView) -> AppHealthPlace?) {
        self.init { id in AppHealthPageFeed.page(forPart: id).flatMap(pages) }
    }

    /// The places of page parts from the daemon's store: the tab the page shows (``PageWebView/healthTabKey``), its
    /// title, and the workspace that holds its pane. A stuck page is always on screen (a hidden page is never timed),
    /// so Show chat brings its window forward and gives the page the keyboard, through the focus route.
    public init(store: DaemonStore) {
        self.init(pages: { [weak store] page in store.flatMap { Self.place(of: page, in: $0) } })
    }

    /// Where `page` is in `store`; nil for a page in no window.
    static func place(of page: PageWebView, in store: DaemonStore) -> AppHealthPlace? {
        guard page.window != nil else { return nil }
        let tab = page.healthTabKey().flatMap(store.tab(idOrResource:))
        let workspace = tab.flatMap(store.pane(holding:)).flatMap { store.workspace(containing: $0.handle) }?.displayName
        let title = tab?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppHealthPlace(chat: title?.isEmpty == false ? title : nil, workspace: workspace?.isEmpty == false ? workspace : nil) { [weak page] in
            guard let page else { return }
            // The person's Show chat: the app, the chat's window and then the page take the keyboard.
            let route = FocusRoute(.person, "app health Show chat")
            route.activateApp()
            route.makeKey(page.window, front: true)
            route.moveKeyboard(in: page.window, to: page)
        }
    }

    /// No part has a place (the parts keep their model labels).
    public static var none: AppHealthPlaces { AppHealthPlaces { _ in nil } }

    /// The place of part `id`, nil when it has none.
    public func callAsFunction(_ id: String) -> AppHealthPlace? { place(id) }

    /// `headline` as the footer line says it: a part with a titled place is named by its title
    /// ("“Fix the login bug” needs a repair"); any other keeps the model's label ("Agent chat").
    public func headline(_ headline: AppHealth.Headline?) -> AppHealth.Headline? {
        guard var headline, let id = headline.partID, let label = label(ofPart: id) else { return headline }
        headline.label = label
        return headline
    }

    /// The name part `id` goes by when its place has a title, nil otherwise.
    func label(ofPart id: String) -> String? {
        place(id)?.chat.map(AppHealthStrings.titled)
    }
}
