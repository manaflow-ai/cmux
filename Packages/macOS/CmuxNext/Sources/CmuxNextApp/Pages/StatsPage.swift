import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextPages

extension InternalPageID {
    static let stats = InternalPageID(rawValue: "stats")
}

/// The Stats page (``StatsPageProvider``, hq#1920) as an internal page tab, one per window. A
/// preview feature until styled: `stats.show` is unavailable without `labs.previewFeatures`.
enum StatsPageTab {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // at launch, so a restored tab finds it; one request line per call to this app's acpmux,
        // and no acpmux answers unavailable.
        services.pages.register(WebPageTab(.stats, symbol: "chart.bar.xaxis", title: StatsPageProvider.title) { [weak services] in
            let socket = services.flatMap(QuitAgents.environment)?.socketPath
            let provider = StatsPageProvider(allowed: { [weak services] in
                services?.settings?.snapshot.previewFeatures == true
            }) { line in
                guard let socket else { return nil }
                return try await AgentActivityLineConnection.oneShot(path: socket, send: line, deadline: .seconds(30))
            }
            return PageWebView(descriptor: .stats, routes: [PageRoute(prefix: "cmux.stats.", provider: provider)])
        })
        registry.bind("stats.show", unavailable: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : StatsPageProvider.previewRefusal
        }, invoke: { [weak services] _ in
            if let services { _ = services.pages.show(.stats, in: services.windows.active, focus: true) }
        })
    }
}
