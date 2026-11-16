public import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// Set Agent Icon… (`agent.harness.setIcon`): `cmux harness icon ID VALUE` from the palette. The
/// palette picks one of the user's own harness profiles (only those have an icon line acpmux
/// edits), then takes the value typed; the request is the one Settings' icon chooser sends
/// (``AgentHarnessIconChange``, `_acpmux/harness/icon`), and acpmux says why it refuses a value.
@MainActor
public struct AgentHarnessIconAction {
    public static let id: ActionID = "agent.harness.setIcon"

    private let setIcon: @MainActor (String, AgentHarnessIconChange) async throws -> Void
    private let state: @MainActor () -> JSONValue
    private let refresh: @MainActor () async -> Void
    private let failure: @MainActor (any Error) -> String

    /// - Parameters:
    ///   - setIcon: Sends the change for a harness id and reads the list again.
    ///   - state: What Settings > Agents draws (`status` and `harnesses` rows).
    ///   - refresh: Reads the harness list again; returns once `state` holds the answer.
    ///   - failure: The text a failed change shows.
    public init(setIcon: @escaping @MainActor (String, AgentHarnessIconChange) async throws -> Void,
                state: @escaping @MainActor () -> JSONValue, refresh: @escaping @MainActor () async -> Void,
                failure: @escaping @MainActor (any Error) -> String) {
        self.setIcon = setIcon
        self.state = state
        self.refresh = refresh
        self.failure = failure
    }

    public func bind(into registry: ActionRegistry) {
        let (setIcon, failure) = (setIcon, failure)
        registry.bindEffect(Self.id, effect: { invocation in
            guard let id = invocation.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                return .refused(Self.text("agentHarness.icon.needsAgent", "Name the agent with --arg id=<agent>."))
            }
            guard let change = AgentHarnessIconChange(["icon": .string(invocation.arguments["icon"]?.stringValue ?? "")]) else {
                return .refused(Self.text("agentHarness.icon.needsIcon", "Name the icon with --arg icon=<emoji, SF Symbol name or agent mark>."))
            }
            // action-wait-allow: acpmux checks the value and rewrites the profile file; nothing local can stand in for its answer
            return .waiting(.externalProcess) {
                do {
                    try await setIcon(id, change)
                    return nil
                } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: failure(error))
                }
            }
        })
        // The pick: the list Settings read. One not read yet (or read while the daemon was down) is read
        // again first, under the palette's loading state, so the step never opens empty and stays so.
        let (state, refresh) = (state, refresh)
        let previous = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.agentHarnessProfiles else { return previous?(source) ?? [] }
            return Self.profileChoices(state())
        }
        let previousLoad = registry.argumentSuggestionsLoad
        registry.argumentSuggestionsLoad = { source in
            guard source == ActionSuggestions.agentHarnessProfiles else { return previousLoad?(source) }
            guard state()["status"]?.stringValue != "ready" else { return nil }
            return {
                await refresh()
                return Self.profileChoices(state())
            }
        }
    }

    /// The rows of Settings' state (`AgentHarnessRows`) acpmux can set an icon on, by id.
    static func profileChoices(_ state: JSONValue) -> [ActionEnumCase] {
        (state["harnesses"]?.arrayValue ?? []).compactMap { row in
            guard row["removable"]?.boolValue == true, let id = row["id"]?.stringValue else { return nil }
            return ActionEnumCase(value: id, title: row["name"]?.stringValue ?? id)
        }
    }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}
