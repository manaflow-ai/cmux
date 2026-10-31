import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextCloud
import CmuxNextPages

extension InternalPageID {
    static let stats = InternalPageID(rawValue: "stats")
    static let artifacts = InternalPageID(rawValue: "artifacts")
}

/// The Stats page (``StatsPageProvider``, hq#1920) and the Artifacts page as internal page tabs, one
/// per window. Preview features until styled: `stats.show` and `artifacts.show` are unavailable
/// without `labs.previewFeatures`.
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
        bindArtifacts(into: registry, context: context)
    }

    /// The Artifacts page (``ArtifactsPageProvider``), the other read-only preview page: the same
    /// gate, and the provider asks again on every read. Signed out, every read answers sign in.
    private static func bindArtifacts(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(WebPageTab(.artifacts, symbol: "shippingbox", title: ArtifactsPageProvider.title) { [weak services] in
            let auth = services?.cloud.auth
            let token: @Sendable () async throws -> String? = { @MainActor in
                guard let auth, auth.isSignedIn else { return nil }
                return try await auth.tokens().access
            }
            let provider = ArtifactsPageProvider(allowed: { [weak services] in services?.settings?.snapshot.previewFeatures == true },
                                                 fetch: ArtifactsPageProvider.platformFetch(base: ArtifactsPageProvider.apiBaseURL(), token: token))
            return PageWebView(descriptor: .artifacts, routes: [PageRoute(prefix: "cmux.artifacts.", provider: provider)])
        })
        registry.bindEffect("artifacts.show", unavailable: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : ArtifactsPageProvider.previewRefusal
        }) { [weak services] invocation in
            // A scripted run opens the tab without taking focus or leaving a top page.
            if let services { _ = services.pages.show(.artifacts, in: services.windows.active, focus: invocation.allowsViewChange) }
            return .done
        }
    }
}

