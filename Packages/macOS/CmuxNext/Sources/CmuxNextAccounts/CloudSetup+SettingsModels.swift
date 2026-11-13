import AppKit
public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Cloud first use (``CloudSetup``, cmux-tui/docs/model-connections.md "Cloud first use", Revision 2)
/// served by Settings > Models (``SettingsModels``): what serves Cloud is this Mac's `_acpmux/connections`
/// and the team's shared keys, and the Set up Cloud card's buttons run Settings > Models' own ways in.
extension CloudSetup {
    /// Serves this setup from a Settings > Models of its own: acpmux at `environment`, the team's
    /// `agentKeys`, `openTerminal` for Claude Code's `claude setup-token`, and `openSettings` for a
    /// Settings page route (``CloudSetup/addRoute``, ``CloudSetup/modelsRoute``).
    public func serve(environment: @escaping @MainActor () -> AcpmuxEnvironment?, agentKeys: TeamAgentKeys,
                      openTerminal: @escaping @MainActor (String) async -> Bool,
                      openSettings: @escaping @MainActor (String) -> Void) {
        let models = SettingsModels(environment: environment, keys: KeychainModelKeyStore(),
                                    openURL: { NSWorkspace.shared.openInBackground($0) },
                                    harnesses: SettingsHarnesses(environment: environment, openTerminal: openTerminal),
                                    agentKeys: agentKeys)
        read = {
            let personal = await environment()?.cloudConnections()
            guard !agentKeys.scopeIsSignedOut else { return Snapshot(personal: personal, organization: nil) }
            if !agentKeys.loaded { await agentKeys.refresh() }
            let rows = agentKeys.currentAgents.compactMap { row in row["agent"]?.stringValue.map { (agent: $0, set: row["set"]?.boolValue == true) } }
            return Snapshot(personal: personal, organization: agentKeys.loaded ? Snapshot.organization(keys: rows) : nil)
        }
        run = { action in await Self.run(action, models: models, openSettings: openSettings) }
        let observing = Observing()
        watching = { [weak self] on in
            observing.task?.cancel()
            observing.task = nil
            guard on else { return models.endWatching() }
            models.beginWatching()
            // task-owner: CloudSetup.watching (Observing.task): one connectionsChanged per change of acpmux's
            // list while a Set up Cloud card waits; the last wait's end cancels it.
            observing.task = Task { [weak self] in
                for await _ in ObservationStream({ models.connections }) { self?.connectionsChanged() }
            }
        }
    }

    /// Settings > Models' Add a Connection (`cmux://settings/models/add`), where the Claude setup token is pasted.
    public nonisolated static let addRoute = "#/settings/models?focus=models.add"
    /// Settings > Models (`cmux://settings/models`).
    public nonisolated static let modelsRoute = "#/settings/models"

    /// One card button: Continue with ChatGPT is Settings > Models' own `connectChatGPT` (the browser
    /// sign-in, acpmux adds the connection); Set up Claude runs `claude setup-token` in a terminal tab
    /// and opens the paste field; Add an API key opens Add a Connection; Open Settings opens Settings > Models.
    /// The click was the person's own (the pane consumed its gesture before this runs).
    private static func run(_ action: Action, models: SettingsModels, openSettings: @MainActor (String) -> Void) async {
        let gesture = PageCallContext(page: "agent", origin: "user", userGesture: true)
        switch action {
        case .connectChatGPT:
            if (try? await models.run(["action": "connectChatGPT"], context: gesture)) == nil { openSettings(addRoute) }
        case .setUpClaude:
            _ = try? await models.run(["action": "claudeSetupToken"], context: gesture)
            openSettings(addRoute)
        case .addKey: openSettings(addRoute)
        case .openSettings: openSettings(modelsRoute)
        }
    }
}

/// The watch of one served ``CloudSetup`` while a card waits.
@MainActor
private final class Observing {
    var task: Task<Void, Never>?
}
