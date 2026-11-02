public import CmuxNextSettings
public import Foundation

// `vm.agent_key.create`'s request body. The method itself is registered by the app, which
// holds the Stack session (CmuxNextApp/Control/AppControl+VMAgentKey.swift).
extension ControlMethod {
    /// The agent-key request: only VM scopes, whatever the caller sent.
    public static func vmAgentKeyRequest(_ params: [String: JSONValue]) throws -> [String: Any] {
        var body: [String: Any] = [
            "name": params["name"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } ?? "cmux vm token",
            "scopes": ["vm:read", "vm:write", "vm:exec"],
        ]
        // A limit that is present must be valid: a bad one is refused, never
        // dropped (the server's default would be larger).
        func invalid(_ name: String) -> ControlError {
            ControlError(code: "invalid_params", message: "\(name) is out of range")
        }
        if let raw = params["ttlSeconds"] {
            guard let ttl = raw.intValue, (60...86_400).contains(ttl) else { throw invalid("ttlSeconds") }
            body["ttlSeconds"] = ttl
        }
        if let raw = params["maxVms"] {
            guard let vms = raw.intValue, (1...20).contains(vms) else { throw invalid("maxVms") }
            body["maxVms"] = vms
        }
        if let raw = params["maxUsdPerHour"] {
            guard let usd = raw.doubleValue, usd.isFinite, usd > 0, usd <= 50 else { throw invalid("maxUsdPerHour") }
            body["maxUsdPerHour"] = usd
        }
        return body
    }
}
