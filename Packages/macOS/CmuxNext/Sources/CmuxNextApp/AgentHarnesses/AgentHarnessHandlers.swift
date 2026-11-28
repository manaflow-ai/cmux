import CmuxNextActions
import CmuxNextSettings
import Foundation

/// The `agent.harness.*` actions (BRING-YOUR-OWN-HARNESS H2) on ``AgentHarnessCenter``: the
/// palette and the model picker's + open Settings > Agents; the CLI and MCP name what to do with
/// arguments and wait for the daemon's answer (tracked work), so a refusal reaches them as
/// `unavailable` with the daemon's reason.
@MainActor
enum AgentHarnessHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let center = context.services.agentHarnesses
        registry.bind("agent.harness.add", run: { invocation in
            var request = AgentHarnessAddRequest()
            request.command = invocation.arguments["command"]?.stringValue
            request.args = AgentHarnessAddRequest.words(invocation.arguments["args"]?.stringValue ?? "")
            request.registry = invocation.arguments["registry"]?.stringValue
            request.example = invocation.arguments["example"]?.stringValue
            request.id = invocation.arguments["id"]?.stringValue
            request.displayName = invocation.arguments["name"]?.stringValue
            request.protocolName = invocation.arguments["protocol"]?.stringValue
            request.replace = invocation.arguments["replace"]?.boolValue ?? false
            guard request.isComplete else {
                // Nothing to start named: a person gets the Add panel, a script the reason.
                guard invocation.origin == .user else { throw ActionFailure(message: AgentHarnessStrings.needsCommand) }
                return try openSettings(context, panel: "add")
            }
            track(registry) { try await center.add(request) }
        })
        registry.bind("agent.harness.addFromRegistry", run: { _ in try openSettings(context, panel: "registry") })
        registry.bind("agent.harness.remove", run: { invocation in
            guard let id = nonEmpty(invocation.arguments["id"]?.stringValue) else {
                guard invocation.origin == .user else { throw ActionFailure(message: AgentHarnessStrings.needsAgent) }
                return try openSettings(context, panel: nil)
            }
            track(registry) { try await center.remove(id: id) }
        })
        registry.bind("agent.harness.restore", run: { invocation in
            // Without a backup: the last removal (Settings' Undo, `cmux agent restore-harness`).
            guard let backup = nonEmpty(invocation.arguments["backup"]?.stringValue) ?? center.lastRemovedBackup else {
                throw ActionFailure(message: AgentHarnessStrings.nothingRemoved)
            }
            track(registry) { try await center.restore(backup: backup) }
        })
        registry.bind("agent.harness.doctor", run: { invocation in
            guard let id = nonEmpty(invocation.arguments["id"]?.stringValue) else {
                guard invocation.origin == .user else { throw ActionFailure(message: AgentHarnessStrings.needsAgent) }
                return try openSettings(context, panel: nil)
            }
            if invocation.origin == .user { try openSettings(context, panel: nil) }
            track(registry) {
                let answer = try await center.doctor(id: id)
                guard answer["ok"]?.boolValue == true else {
                    let failed = answer["steps"]?.arrayValue?.first { $0["ok"]?.boolValue == false }
                    throw ActionFailure(message: AgentHarnessStrings.doctorFailed(
                        id, step: failed?["name"]?.stringValue ?? "doctor",
                        detail: [failed?["detail"]?.stringValue, failed?["fix"]?.stringValue].compactMap { $0 }.joined(separator: " ")))
                }
                return answer
            }
        })
    }

    /// Settings > Agents, with its Add panel (`add`) or registry list (`registry`) open.
    static func openSettings(_ context: AppActionContext, panel: String?) throws {
        let route = "#/settings/agents" + (panel.map { "?focus=agents.\($0)" } ?? "")
        try context.services.settingsWindow.show(section: nil, focus: true, route: route)
    }

    /// Runs `work` as the action's tracked work: the CLI and MCP wait for it; a failure answers
    /// `unavailable` with its reason (the daemon's text).
    private static func track(_ registry: ActionRegistry, _ work: @escaping @MainActor () async throws -> JSONValue) {
        registry.track(Task { @MainActor in
            do {
                _ = try await work()
                return nil
            } catch {
                return ActionWorkFailure(refusal: .unavailable, reason: AgentHarnessCenter.text(error))
            }
        })
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

nonisolated enum AgentHarnessStrings {
    static var noDaemon: String { text("handlers.agent.harness.noDaemon", "The agent daemon is not running. Open an agent chat to start it, then try again.") }
    static var unsupported: String {
        text("handlers.agent.harness.unsupported", "This acpmux cannot add or remove agents from the app. Use cmux harness add or cmux harness doctor in a terminal.")
    }
    static var needsAgent: String { text("handlers.agent.harness.needsAgent", "Name the agent with --arg id=<agent>.") }
    static var needsCommand: String {
        text("handlers.agent.harness.needsCommand", "Name what to start: --arg command=<program>, --arg registry=<id> or --arg example=<id>.")
    }
    static var nothingRemoved: String { text("handlers.agent.harness.nothingRemoved", "No removed agent to restore. Name its backup file with --arg backup=<file>.") }

    static func doctorFailed(_ id: String, step: String, detail: String) -> String {
        String(format: text("handlers.agent.harness.doctorFailed", "%@ failed its check at %@: %@"), id, step, detail)
    }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "MiscHandlers", bundle: .module)
    }
}
