import AppKit
import CmuxNextPages

/// The channels Home as an internal page tab, one per window: a pane tab, so it sits next to the
/// native Home (and any other tab) in a split. Opened by "Open Channels" (palette, File menu,
/// `cmux home channels`).
@MainActor
final class HomeChannelsPageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]
    /// Routes for store tabs whose view is not made yet (the docked Home's tab before its first
    /// show), by tab id; `makeView` applies the one of its own tab.
    private var pendingRoutes: [String: String] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .homeChannels }
    var title: String { HomeChannelsStrings.title }
    var symbol: String { "number" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let view = PageFactory(services: services).homeChannelsWebPage() else { return NSView() }
        // A web link the person clicks opens on the Home workspace's right side (cx-ebm.59.6).
        view.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
        if let pending = pendingRoutes.first(where: { services.pages.storeKey(of: $0.key) == key }) {
            pendingRoutes[pending.key] = nil
            view.open(route: pending.value)
            // The person asked for this page: it takes the keyboard once it draws in its window.
            view.whenPainted { [weak view] in view?.focusPage() }
        }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }

    /// Shows `route` in the page of store tab `tabID` (the docked Home) and gives it the keyboard;
    /// before the tab's first show, its view opens there. The page follows its hash, so the same
    /// route again ("#/" first) opens it again after the person moved on (hq-ec's contract).
    func open(route: String, tabID: String, services: AppServices) {
        guard let key = services.pages.storeKey(of: tabID), let view = pages[key] else {
            pendingRoutes[tabID] = route
            return
        }
        if view.route == "#" + route { view.open(route: "/") }
        view.open(route: route)
        if view.window != nil { view.focusPage() } else { view.whenPainted { [weak view] in view?.focusPage() } }
    }

    /// Opens (or selects) the channels tab in the active window.
    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true) -> Bool {
        if services.pages.provider(.homeChannels) == nil { services.pages.register(HomeChannelsPageTab(services: services)) }
        return services.pages.show(.homeChannels, in: services.windows.active, focus: focus) != nil
    }
}

nonisolated enum HomeChannelsStrings {
    static var title: String { String(localized: "homeChannels.page.title", defaultValue: "Channels", table: "Handlers", bundle: .module) }
}
