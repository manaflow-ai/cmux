import Foundation
import CMUXAgentLaunch

// Compose Feed persistence and its app-owned identity/title adapters.
extension AppDelegate {
    @MainActor
    func installFeedStore() {
        // Install the Feed (workstream) store. Separate from the transport
        // wiring: the store is a plain singleton here, and the socket
        // `feed.*` V2 verbs in `TerminalController` push into it directly
        // via `FeedCoordinator`.
        FeedCoordinator.shared.install(
            store: WorkstreamStore(
                transport: NullWorkstreamTransport(),
                persistence: WorkstreamPersistence(fileURL: WorkstreamPersistence.defaultFileURL()),
                workstreamIDNormalizer: { rawValue, source in
                    FeedWorkstreamIdentifier.canonicalizedRawValue(
                        agentID: source,
                        rawValue: rawValue
                    )
                },
                titleProvider: Self.feedWorkstreamTitle(for:),
                // Keep startup fail-closed even when a large or damaged
                // append-only history is slow to decode. The diagnostic
                // budget remains shorter and reports pressure without
                // discarding otherwise recoverable rows.
                startupHardBudgetNanoseconds: 5_000_000_000
            )
        )
        StartupBreadcrumbLog.append("appDelegate.didFinish.feedStore.installed")
    }
}
