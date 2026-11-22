import AppKit
import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeEngine

extension InternalPageID {
    /// The native Home as a pane tab (`home.tab`). Its own id: the Home top page is a `TopPageRoute`, never a page tab.
    static let homeTab = InternalPageID(rawValue: "home-tab")
}

/// The native Home (MessagesLab's list and transcript, `TopHomePageView`) as an internal page tab, so it sits in a
/// split next to any other tab, the channels Home among them. Every tab reads the one `HomeService` (`services.home`):
/// a message sent in one Home shows in every other Home at once. Each `home.tab` run opens one more tab; each tab
/// has its own list selection, composer draft and width. The Home top page (`home.show`) stays as it is.
@MainActor
final class HomePageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var views: [String: TopHomePageView] = [:]
    /// The order the tabs opened in (`debug.home` lists them so).
    private var order: [String] = []
    /// The saved list width every Home tab shares (`HomeSidebarWidth` keeps one width per key; one per tab would grow).
    static let widthKey = "home-tab"

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .homeTab }
    var title: String { HomeStrings.title }
    var symbol: String { "house" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let view = TopHomePageView(services: services, windowKey: { Self.widthKey })
        views[key] = view
        order.append(key)
        return view
    }

    func tabClosed(_ key: String) { views[key] = nil; order.removeAll { $0 == key } }

    /// Open Home tabs by provider key, in the order they opened.
    var tabs: [(key: String, view: TopHomePageView)] { order.compactMap { key in views[key].map { (key, $0) } } }

    /// `home.tab`: one more Home tab in the active window, after the focused pane's selected tab. With
    /// `direction` (`home.tabLeft`, `home.tabRight`; Leo, 2026-11-22: "you should be able to simply open it
    /// to the left or right of your current tab or pane or split") it then moves as Move Tab to New Split
    /// does, unless made from a chat dock, which never splits. A user run selects and focuses it (and leaves
    /// a top page); automation opens it without changing the view. False when no pane can hold it.
    @discardableResult
    static func open(_ services: AppServices, focus: Bool, direction: String? = nil) -> Bool {
        if services.pages.provider(.homeTab) == nil { services.pages.register(HomePageTab(services: services)) }
        let window = services.windows.active, content = window?.workspaceContent, model = content?.pageTabModelPane
        guard let direction, let window, let model, let pane = content?.controller(for: model),
              !ChatDockRules.isChatDock(model, services: services) else { return services.pages.openNew(.homeTab, in: window, focus: focus) != nil }
        if focus { window.leaveTopPage() }
        let daemon = pane.daemon
        return services.pages.openStoreTab(.homeTab, in: pane, window: window, focus: focus, created: { [weak services] surface in
            guard let tab = daemon.store.tab(surface: surface) else { return }
            let move = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), arguments: ["direction": .string(direction), "keepFocus": .bool(!focus)])
            _ = services?.registry.perform("tab.moveToNewSplit", invocation: move.onMachine(daemon.machineID))
        }) != nil || services.pages.openNew(.homeTab, in: window, focus: focus) != nil
    }
}
