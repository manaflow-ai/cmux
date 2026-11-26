import Foundation
import CmuxControlSocket

extension TerminalController {
    private nonisolated static let automationCommandEnvelopePrefix = "__cmux_automation_origin "

    nonisolated static func automationFocusSuppressedMessage() -> String {
        String(
            localized: "automation.error.focusSuppressed",
            defaultValue: "This automation action requires permission to focus or select a surface. Update the rule to allow focus, then try again."
        )
    }

    nonisolated static func automationRuleNotFoundMessage(_ id: String) -> String {
        let format = String(
            localized: "automation.error.ruleNotFound",
            defaultValue: "Automation rule not found: %@"
        )
        return String.localizedStringWithFormat(format, id)
    }

    nonisolated static func automationCommandEnvelope(
        from command: String
    ) -> (command: String, origin: CmuxAutomationEventOrigin)? {
        guard command.hasPrefix(automationCommandEnvelopePrefix) else { return nil }
        let remainder = command.dropFirst(automationCommandEnvelopePrefix.count)
        let parts = remainder.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let data = Data(base64Encoded: parts[0]),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ruleID = raw["rule_id"] as? String,
              !ruleID.isEmpty else {
            return nil
        }
        let chain = (raw["chain"] as? [String] ?? [ruleID])
            .filter { !$0.isEmpty }
            .prefix(16)
            .map { String($0.prefix(256)) }
        return (
            command: parts[1],
            origin: CmuxAutomationEventOrigin(
                ruleID: ruleID,
                chain: chain.isEmpty ? [ruleID] : chain
            )
        )
    }

    @MainActor
    func attachAutomationEngine(_ engine: AutomationEngine) {
        automationEngine = engine
    }

    @MainActor
    func stopAutomationEngine() {
        automationEngine?.stop()
    }

    @MainActor
    func v2AutomationList() -> V2CallResult {
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation is unavailable. Check ~/.cmuxterm/automations.json, then run cmux automation reload."),
                data: nil
            )
        }
        return .ok(["rules": automationEngine.listPayload()])
    }

    @MainActor
    func v2AutomationShow(params: [String: Any]) -> V2CallResult {
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "automation.error.missingRuleID", defaultValue: "Missing automation rule id"),
                data: nil
            )
        }
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation is unavailable. Check ~/.cmuxterm/automations.json, then run cmux automation reload."),
                data: nil
            )
        }
        guard let payload = automationEngine.showPayload(id: id) else {
            return .err(
                code: "not_found",
                message: Self.automationRuleNotFoundMessage(id),
                data: ["id": id]
            )
        }
        return .ok(payload)
    }

    @MainActor
    func v2AutomationTest(params: [String: Any]) -> V2CallResult {
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "automation.error.missingRuleID", defaultValue: "Missing automation rule id"),
                data: nil
            )
        }
        guard let event = params["event"] as? [String: Any] else {
            return .err(
                code: "invalid_params",
                message: String(localized: "automation.error.testEventObject", defaultValue: "automation.test requires event object"),
                data: nil
            )
        }
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation is unavailable. Check ~/.cmuxterm/automations.json, then run cmux automation reload."),
                data: nil
            )
        }
        guard let payload = automationEngine.testPayload(id: id, event: event) else {
            return .err(
                code: "not_found",
                message: Self.automationRuleNotFoundMessage(id),
                data: ["id": id]
            )
        }
        return .ok(payload)
    }

    @MainActor
    func v2AutomationSetEnabled(params: [String: Any], enabled: Bool) -> V2CallResult {
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "automation.error.missingRuleID", defaultValue: "Missing automation rule id"),
                data: nil
            )
        }
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation is unavailable. Check ~/.cmuxterm/automations.json, then run cmux automation reload."),
                data: nil
            )
        }
        guard automationEngine.scheduleSetEnabled(id: id, enabled: enabled) else {
            return .err(
                code: "not_found",
                message: Self.automationRuleNotFoundMessage(id),
                data: ["id": id]
            )
        }
        return .ok([
            "id": id,
            "enabled": enabled,
            "pending": true,
            "completion": "automation.logs"
        ])
    }

    @MainActor
    func v2AutomationLogs(params: [String: Any]) -> V2CallResult {
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation is unavailable. Check ~/.cmuxterm/automations.json, then run cmux automation reload."),
                data: nil
            )
        }
        let limit = (params["limit"] as? NSNumber)?.intValue ?? 100
        return .ok(["logs": automationEngine.logsPayload(limit: limit)])
    }

    @MainActor
    func v2AutomationReload() -> V2CallResult {
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation is unavailable. Check ~/.cmuxterm/automations.json, then run cmux automation reload."),
                data: nil
            )
        }
        automationEngine.scheduleReload()
        return .ok([
            "reloading": true
        ])
    }

    /// Dispatches an automation RPC through the normal v2 execution policy.
    /// The task-local focus allowance is false by default, so even inherently
    /// focus-oriented methods preserve the user's selection unless the action
    /// explicitly opts in with `allow_focus`/`focus`.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func performAutomationRPC(
        method: String,
        params: [String: Any],
        allowFocus: Bool,
        origin: CmuxAutomationEventOrigin
    ) async -> String {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request, options: []),
              let line = String(data: data, encoding: .utf8) else {
            return "ERROR: " + String(
                localized: "automation.error.encodeRPC",
                defaultValue: "Could not prepare the automation action. Check the rule configuration and try again."
            )
        }
        return await CmuxAutomationInvocationContext.$focusAllowed.withValue(allowFocus) {
            await CmuxAutomationInvocationContext.$eventOrigin.withValue(origin) {
                let response = await processCommandUsingSocketExecutionPolicyAsync(line) ?? ""
                // Normal socket clients pass through this mapper after the
                // dispatcher returns. Automation RPCs are in-process, so call
                // the same shared path here while the origin task-local is
                // still active.
                publishSocketEvents(command: line, response: response)
                return response
            }
        }
    }
}
