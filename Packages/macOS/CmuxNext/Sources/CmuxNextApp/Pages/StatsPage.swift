import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextCompat
import CmuxNextCloud
import CmuxNextPages

extension InternalPageID {
    static let stats = InternalPageID(rawValue: "stats")
    static let artifacts = InternalPageID(rawValue: "artifacts")
}

/// The Stats page (``StatsPageProvider``, hq#1920) and the Artifacts page as internal page tabs, one per
/// window. Stats is a preview feature until styled: `stats.show` needs `labs.previewFeatures`.
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
        // The Artifacts page (``ArtifactsPageProvider``): on for everyone; signed out, every read answers sign in.
        services.pages.register(WebPageTab(.artifacts, symbol: "shippingbox", title: ArtifactsPageProvider.title) { [weak services] in
            let baseURL = services?.cloud.configuration.artifactsAPIBaseURL()
            let auth = services?.cloud.auth
            let authChanges = auth.map { auth in ArtifactsPageProvider.authChanges { auth.isSignedIn ? auth.user?.id : nil } }
            return ArtifactsPageProvider.page(baseURL: baseURL, authChanges: authChanges) { @MainActor in
                guard let auth, auth.isSignedIn else { return nil }
                return try await auth.tokens().access
            }
        })
        registry.bindEffect("artifacts.show") { [weak services] invocation in
            if let services { _ = services.pages.show(.artifacts, in: services.windows.active, focus: invocation.allowsViewChange) }
            return .done
        }
    }
}
