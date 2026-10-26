public import Foundation

/// The page's reply envelope: `{ok: true, value}` or
/// `{ok: false, error: {code, userMessage, details?, retryable?, origin?}}`.
public nonisolated enum AgentPaneReply {
    /// JSON-compatible dictionaries for the `WKScriptMessageHandlerWithReply`
    /// reply handler, which bridges them to JavaScript objects.
    public static func success(_ value: Any = NSNull()) -> [String: Any] {
        ["ok": true, "value": value]
    }

    public static func failure(code: String, message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "userMessage": message]]
    }

    /// A failure that says who failed (`origin`) and carries the session
    /// host's `details` (a JSON-compatible value) and `retryable`. Nil fields
    /// are left out so the page sees `undefined`.
    public static func failure(code: String, message: String, details: Any?, retryable: Bool?, origin: String) -> [String: Any] {
        var error: [String: Any] = ["code": code, "userMessage": message, "origin": origin]
        if let details { error["details"] = details }
        if let retryable { error["retryable"] = retryable }
        return ["ok": false, "error": error]
    }

    /// A Sandboxed send's reply (`sandbox.run`, hq#3367): `{receipt}` from the Run's final snapshot,
    /// or the failure's typed code alone (`labs_off`, `not_signed_in`, `run_sandbox_unavailable`,
    /// `timeout`, …), which the page words itself. A snapshot with no receipt is `bad_response`.
    /// Nothing else crosses to the page: no Run id, no request path or error text (they name
    /// provider handles); the receipt holds no secrets or provider handles (the server redacts it).
    public static func sandbox(_ run: () async throws -> [String: Any], code: (any Error) -> String) async -> [String: Any] {
        do {
            let snapshot = try await run()
            guard let receipt = snapshot["receipt"] as? [String: Any] else {
                return failure(code: "bad_response", message: "bad_response")
            }
            return success(["receipt": receipt])
        } catch {
            let typed = sandboxCodes.contains(code(error)) ? code(error) : "unavailable"
            return failure(code: typed, message: typed)
        }
    }

    /// The failure codes a Sandboxed reply may carry, the ones the page words (sandboxRun.ts
    /// `sandboxFailureKey`, `DEFINITE_REFUSALS`). Any other code, such as one the server or a
    /// header sent that may name a provider handle, reaches the page as `unavailable` (a failure
    /// that may hide a live Run).
    static let sandboxCodes: Set<String> = [
        "labs_off", "not_signed_in", "cloud_disabled", "timeout", "unavailable", "unavailable_now", "bad_response",
        "sandbox_busy", "sandbox_spent", "run_sandbox_unavailable", "run_task_required", "run_agent_invalid",
        "run_image_invalid", "run_timeout_invalid", "run_attempts_invalid", "run_environment_invalid", "run_invalid_request",
    ]

    /// The handshake as the dictionary the page receives. Nil fields are left
    /// out so the page sees `undefined`, as the TypeScript type expects. The
    /// Codable DTO is encoded once at the bridge boundary; NewTab projection
    /// and presentation limits belong to the web page.
    public static func handshake(_ handshake: AgentPaneHandshake) -> [String: Any] {
        var value = encodedObject(handshake)
        value["handoffStrings"] = AgentPaneHandoffStrings().values
        value["checkpointStrings"] = AgentPaneCheckpointStrings().values
        return success(value)
    }

    private static func encodedObject<Value: Encodable>(_ value: Value) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            assertionFailure("Agent pane bridge value must be JSON-compatible")
            return [:]
        }
        return dictionary
    }
}
