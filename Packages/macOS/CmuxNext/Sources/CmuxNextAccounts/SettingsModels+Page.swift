public import AppKit
public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextCompat
import CmuxNextWakeups
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The Settings page's `cmux.settings.models.*` (webviews/src/pages/settings/ops.ts): `state` (after the
/// first read), `run`, and the `changed` stream, which watches acpmux's changes while a page shows the card.
extension SettingsModels: PageProvider {
    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.models.state": return await loadedState()
        case "cmux.settings.models.run": return try await run(params, context: context)
        default: throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.settings.models.changed" else { throw PageError.unknownOp(stream) }
        beginWatching()
        let initial = state
        // task-owner: SettingsModels.subscribe: one event per change of the card's state; the subscription's cancel ends it.
        let task = Task { [weak self] in
            var last = initial
            for await value in ObservationStream({ [weak self] in self?.state ?? .null }) where value != last {
                last = value
                onEvent(value)
            }
        }
        // The subscription holds the card's model until it ends; its end may come off the main actor.
        return PageSubscription { [self] in
            task.cancel()
            MainDelivery().run { self.endWatching() }
        }
    }

    /// The app's Settings > Models: acpmux at `environment`, the person's browser for the ChatGPT sign-in,
    /// the Claude account sign-in of `harnesses`, `models.spreadUsage` through `settings`' one writer, and the
    /// active team (none for the personal team) with its keys and policy.
    public static func live(environment: @escaping @MainActor () -> AcpmuxEnvironment?, harnesses: SettingsHarnesses,
                            settings: SettingsController, activeTeam: @escaping @MainActor () -> ActiveTeam?,
                            agentKeys: TeamAgentKeys, policy: TeamModelsPolicy) -> SettingsModels {
        SettingsModels(
            environment: environment, keys: KeychainModelKeyStore(),
            openURL: { NSWorkspace.shared.openInBackground($0) },
            harnesses: harnesses,
            team: {
                guard !agentKeys.isPersonal, let team = activeTeam()?.team else { return nil }
                return (team.id, team.displayName)
            },
            agentKeys: agentKeys, policy: policy,
            spreadSetting: { ModelsSettings(root: settings.snapshot.root).spreadUsage },
            writeSpreadSetting: { on in
                let value: JSONValue? = on == ModelsSettings.spreadUsageDefault ? nil : .bool(on)
                try await settings.setSetting(at: ModelsSettings.spreadUsagePath, to: value, by: .user)
            })
    }

    /// The app's mirror of `models.spreadUsage` into acpmux for its whole life: one push per change, from any
    /// writer (Settings, the palette, `cmux settings`, MCP). Cancel the task to end it.
    public static func mirrorSpread(settings: @escaping @MainActor @Sendable () -> SettingsController?,
                                    environment: @escaping @MainActor () -> AcpmuxEnvironment?) -> Task<Void, Never> {
        // task-owner: the caller (AccountsService.spreadMirror) keeps it for the app's life.
        Task {
            for await on in ObservationStream({ ModelsSettings(root: settings()?.snapshot.root ?? .null).spreadUsage }) {
                guard let environment = environment() else { continue }
                await pushSpread(on, environment: environment)
            }
        }
    }
}
