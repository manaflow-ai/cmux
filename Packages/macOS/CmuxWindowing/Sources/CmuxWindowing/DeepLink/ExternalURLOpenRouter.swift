public import Foundation

/// Orchestrates `NSApplicationDelegate.application(_:open:)`: the ordered deep-
/// link open flow for external URLs handed to the app (Finder/Dock opens, auth
/// callbacks, `cmux://` deep links).
///
/// The flow is: let the app's own cmux-scheme external routes consume the URLs
/// first; otherwise route any auth callbacks through the auth graph, then build
/// the partitioned ``DeepLinkOpenPlan`` from the classified file URLs and
/// directories and execute each member in order (run terminal-eligible files,
/// preview the rest, open directories as workspaces).
///
/// It owns no state. The pure URL partitioning lives behind the injected
/// ``DeepLinkRouting``; every live window/workspace/auth effect is delegated to
/// the app-target ``ExternalURLOpenRouterHost`` injected at construction. The
/// router never touches AppKit or main-window state itself, so the `@MainActor`
/// isolation only reflects that it is driven from the main-actor delegate entry
/// and calls main-actor host effects without a hop.
@MainActor
public final class ExternalURLOpenRouter {
    private let router: any DeepLinkRouting
    private let host: any ExternalURLOpenRouterHost

    /// Creates a router that partitions opens with `router` and performs each
    /// effect through `host`.
    public init(router: any DeepLinkRouting, host: any ExternalURLOpenRouterHost) {
        self.router = router
        self.host = host
    }

    /// Handles an external open intent for `urls`, executing the ordered
    /// deep-link open flow.
    public func open(urls: [URL]) {
        if host.handleExternalRoutes(urls) {
            return
        }

        host.handleAuthCallbacks(urls)

        let plan = router.openPlan(
            externalFileURLs: host.classifiedFileURLs(from: urls),
            directories: host.classifiedDirectories(from: urls)
        )
        guard !plan.isEmpty else { return }

        host.prepareForExplicitOpenIntentAtStartup()
        for request in plan.terminalFileRequests {
            host.openTerminalDefaultFileRequest(
                request,
                debugSource: "application.openURLs.defaultTerminal"
            )
        }
        for filePath in plan.filePreviewPaths {
            host.openFilePreview(
                filePath: filePath,
                debugSource: "application.openURLs"
            )
        }
        for directory in plan.directories {
            host.openWorkspaceForExternalDirectory(
                directory,
                debugSource: "application.openURLs"
            )
        }
    }
}
