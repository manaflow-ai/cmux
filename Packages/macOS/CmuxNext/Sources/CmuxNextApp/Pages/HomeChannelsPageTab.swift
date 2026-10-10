import AppKit
import CmuxNextPages

/// The channels Home as an internal page tab, one per window: a pane tab, so it sits next to the
/// native Home (and any other tab) in a split. Opened by "Open Channels" (palette, File menu,
/// `cmux home channels`).
@MainActor
final class HomeChannelsPageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .homeChannels }
    var title: String { HomeChannelsStrings.title }
    var symbol: String { "number" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let view = PageFactory(services: services).homeChannelsWebPage() else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        pages.removeValue(forKey: key)?.close()
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
