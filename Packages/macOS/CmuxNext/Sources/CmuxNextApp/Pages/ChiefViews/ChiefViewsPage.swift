import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextDesign
import CmuxNextHome
import CmuxNextPages

extension PageDescriptor {
    /// The Chief view gallery (webviews/src/pages/chief-views): experimental views beside the Chief,
    /// over the agents the app already mirrors, the CI fleet dashboard and the repository's PRs.
    static let chiefViews = PageDescriptor(
        id: "cmux.chief-views", resource: "chief-views", namespaces: [ChiefViewsPageProvider.prefix])
}

extension InternalPageID {
    static let chiefViews = InternalPageID(rawValue: "chief-views")
}

/// Debug Settings > Home > "Chief view gallery": on in DEV and NIGHTLY by default; Release and RC
/// never offer it (``ChiefViewsPageTab/isAvailable``).
nonisolated enum ChiefViewsTunables {
    static let gallery = Tunable<Bool>.toggle(
        "home.chiefViewGallery", HomeTunables.section, "Chief view gallery",
        help: "Offers Chief View Gallery (palette): experimental views beside the Chief, such as where every agent is, an agent board, the CI fleet, landing PRs and today's timeline. One view is on at first; the gallery turns on the others.",
        default: true, code: "ChiefViewsTunables.gallery")

    static var all: [TunableDescriptor] { [gallery.descriptor] }
}

/// The Chief view gallery as an internal page tab, one per window. `chief.openViews` (palette,
/// `cmux action run`) shows it: in the home workspace a page tab lands in the column beside the
/// Chief dock, Home's right column. The views and where each opens (pane, split or sidebar) are
/// the page's own (webviews/src/pages/chief-views/registry.ts); this tab only serves their data.
@MainActor
final class ChiefViewsPageTab: InternalPageProvider {
    static let actionID: ActionID = "chief.openViews"

    /// DEV and NIGHTLY with the Debug Settings toggle on.
    static var isAvailable: Bool { DevTools.isEnabled && ChiefViewsTunables.gallery.value }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(ChiefViewsPageTab(services: services)) // at launch, so a restored tab finds it
        registry.bind(actionID, unavailable: {
            isAvailable ? nil : ChiefViewsStrings.off
        }, invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(.chiefViews, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
    }

    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .chiefViews }
    var title: String { ChiefViewsStrings.title }
    var symbol: String { "square.grid.2x2" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let provider = ChiefViewsPageProvider(host: Self.host(services))
        guard let view = PageWebView(descriptor: .chiefViews, routes: [PageRoute(prefix: ChiefViewsPageProvider.prefix, provider: provider)]) else {
            return NSView()
        }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }

    /// The live host: the app's lanes and tabs, the network, this app's defaults.
    private static func host(_ services: AppServices) -> ChiefViewsPageProvider.Host {
        ChiefViewsPageProvider.Host(
            agents: { [weak services] in
                guard let services else { return [] }
                return ChiefViewsAgent.current(lanes: .shared, services: services)
            },
            fetch: ChiefViewsPageProvider.liveFetch,
            defaults: .standard,
            environment: ProcessInfo.processInfo.environment,
            now: { Date() },
            openAgent: { [weak services] kind, id in
                guard let services else { return }
                switch kind {
                case .chat:
                    try DeepLinkNavigator(services: services).open(DeepLink(.session(id, turn: nil)), background: false)
                case .terminal:
                    guard services.revealTab(id) else { throw ActionFailure(message: ChiefViewsStrings.gone) }
                }
            },
            openURL: { [weak services] url in
                services?.home.dock.openLink(url, on: services?.daemon.connection)
            })
    }
}

/// The gallery's native strings (table `ChiefViews`); the page's own text is
/// webviews/src/pages/chief-views/Localizable.xcstrings.
struct ChiefViewsStrings {
    static var title: String { t("chiefViews.tab.title", "Views") }
    static var off: String {
        t("chiefViews.refusal.off", "The Chief view gallery is off. Turn on Chief view gallery in Debug Settings > Home.")
    }
    static var fleetUnset: String { t("chiefViews.fleet.unset", "No CI dashboard is set.") }
    static var fleetUnreachable: String { t("chiefViews.fleet.unreachable", "The CI dashboard did not answer.") }
    static var landingUnreachable: String {
        t("chiefViews.landing.unreachable", "GitHub did not answer. Try Refresh in a minute.")
    }
    static var gone: String { t("chiefViews.open.gone", "That agent is no longer running.") }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ChiefViews", bundle: .module)
    }
}
