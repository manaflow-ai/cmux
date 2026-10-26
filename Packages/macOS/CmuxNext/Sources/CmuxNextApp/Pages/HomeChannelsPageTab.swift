import AppKit
import CmuxNextHibernation
import CmuxNextPages

/// The channels Home as an internal page tab, one per window: a pane tab, so it sits next to the
/// native Home (and any other tab) in a split. Opened by "Open Channels" (palette, File menu,
/// `cmux home channels`).
@MainActor
final class HomeChannelsPageTab: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]
    /// What each tab's page says about its composers' unsent input.
    private var inputs: [String: HomeChannelsInput] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .homeChannels }
    var title: String { HomeChannelsStrings.title }
    var symbol: String { "number" }

    static func make(_ services: AppServices) -> HomeChannelsPageTab { HomeChannelsPageTab(services: services) }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let input = HomeChannelsInput()
        guard let services, let view = PageFactory(services: services).homeChannelsWebPage(input: input) else { return NSView() }
        view.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
        pages[key] = view
        inputs[key] = input
        return view
    }

    func tabClosed(_ key: String) {
        inputs[key] = nil
        pages.removeValue(forKey: key)?.close()
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, unless a composer holds unsent input (``keepReasons(for:)``).
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// A composer's unsent text or files live only in the page: while the page reports some, it
    /// stays (Chrome's `kFormInteractions`, discard_eligibility_policy.cc).
    func keepReasons(for key: String) -> [CannotDiscardReason] { inputs[key]?.keepReasons ?? [] }

    /// The discard closed the page with its view; the tab's next show makes a new one.
    func viewDiscarded(_ key: String) {
        inputs[key] = nil
        pages[key] = nil
    }

    /// Tab `key`'s input report, while its page exists.
    func input(for key: String) -> HomeChannelsInput? { inputs[key] }

    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true) -> Bool {
        if services.pages.provider(.homeChannels) == nil { services.pages.register(make(services)) }
        return services.pages.show(.homeChannels, in: services.windows.active, focus: focus) != nil
    }
}

nonisolated enum HomeChannelsStrings {
    static var title: String { String(localized: "homeChannels.page.title", defaultValue: "Channels", table: "Handlers", bundle: .module) }
}
