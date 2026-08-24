import Foundation
import CmuxControlSocket

extension TerminalController {
    nonisolated static func automationOrigin(from command: String) -> CmuxAutomationEventOrigin? {
        guard command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              let data = command.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["automation_origin"] as? [String: Any],
              let ruleID = raw["rule_id"] as? String,
              !ruleID.isEmpty else {
            return nil
        }
        let chain = (raw["chain"] as? [String] ?? [ruleID])
            .filter { !$0.isEmpty }
            .prefix(16)
            .map { String($0.prefix(256)) }
        return CmuxAutomationEventOrigin(ruleID: ruleID, chain: chain.isEmpty ? [ruleID] : chain)
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
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation engine is not available"),
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
        guard let automationEngine,
              let payload = automationEngine.showPayload(id: id) else {
            return .err(
                code: "not_found",
                message: String(localized: "automation.error.ruleNotFound", defaultValue: "Automation rule not found"),
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
        guard let automationEngine,
              let payload = automationEngine.testPayload(id: id, event: event) else {
            return .err(
                code: "not_found",
                message: String(localized: "automation.error.ruleNotFound", defaultValue: "Automation rule not found"),
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
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation engine is not available"),
                data: nil
            )
        }
        switch automationEngine.setEnabled(id: id, enabled: enabled) {
        case .success(let rule):
            return .ok([
                "id": rule.id,
                "enabled": rule.enabled
            ])
        case .failure(let error):
            let code: String
            if let configError = error as? AutomationConfigStoreError,
               case .ruleNotFound = configError {
                code = "not_found"
            } else {
                code = "invalid_config"
            }
            return .err(code: code, message: error.localizedDescription, data: ["id": id])
        }
    }

    @MainActor
    func v2AutomationLogs(params: [String: Any]) -> V2CallResult {
        guard let automationEngine else {
            return .err(
                code: "unavailable",
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation engine is not available"),
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
                message: String(localized: "automation.error.engineUnavailable", defaultValue: "Automation engine is not available"),
                data: nil
            )
        }
        switch automationEngine.reload() {
        case .success(let count):
            return .ok(["reloaded": true, "rule_count": count])
        case .failure(let error):
            return .err(code: "invalid_config", message: error.localizedDescription, data: nil)
        }
    }

    /// Dispatches an automation RPC through the normal v2 execution policy.
    /// The task-local focus allowance is false by default, so even inherently
    /// focus-oriented methods preserve the user's selection unless the action
    /// explicitly opts in with `allow_focus`/`focus`.
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
                defaultValue: "Failed to encode automation RPC request"
            )
        }
        return await CmuxAutomationInvocationContext.$focusAllowed.withValue(allowFocus) {
            await CmuxAutomationInvocationContext.$eventOrigin.withValue(origin) {
                await processCommandUsingSocketExecutionPolicyAsync(line) ?? ""
            }
        }
    }
}
