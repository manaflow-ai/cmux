import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextPages

extension InternalPageID {
    static let stats = InternalPageID(rawValue: "stats")
}

/// The Stats page (``StatsPageProvider``, hq#1920) as an internal page tab, one per window. A
/// preview feature until styled: `stats.show` is unavailable without `labs.previewFeatures`.
@MainActor
final class StatsPageTab: InternalPageProvider {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(StatsPageTab(services: services)) // at launch, so a restored tab finds it
        registry.bind("stats.show", unavailable: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : StatsPageProvider.previewRefusal
        }, invoke: { [weak services] _ in
            if let services { _ = services.pages.show(.stats, in: services.windows.active, focus: true) }
        })
    }

    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .stats }
    var title: String { StatsPageProvider.title }
    var symbol: String { "chart.bar.xaxis" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // One request line per call to this app's acpmux; no acpmux answers unavailable.
        let socket = services.flatMap(QuitAgents.environment)?.socketPath
        let provider = StatsPageProvider(allowed: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true
        }) { line in
            guard let socket else { return nil }
            return try await AgentActivityLineConnection.oneShot(path: socket, send: line, deadline: .seconds(30))
        }
        guard let view = PageWebView(descriptor: .stats, routes: [PageRoute(prefix: "cmux.stats.", provider: provider)]) else { return NSView() }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }
}
