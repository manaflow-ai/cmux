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
    /// provider handles), and of the receipt only the fields the chat shows (``pageReceipt(_:)``).
    public static func sandbox(_ run: () async throws -> [String: Any], code: (any Error) -> String) async -> [String: Any] {
        do {
            let snapshot = try await run()
            guard let receipt = snapshot["receipt"] as? [String: Any] else {
                return failure(code: "bad_response", message: "bad_response")
            }
            return success(["receipt": pageReceipt(receipt)])
        } catch {
            let typed = isSandboxCode(code(error)) ? code(error) : "unavailable"
            return failure(code: typed, message: typed)
        }
    }

    /// The receipt's fields the chat shows (SandboxRunView), each of its own type; the rest (the
    /// Run id, the image, the launcher's error text, digests) stays here.
    static func pageReceipt(_ receipt: [String: Any]) -> [String: Any] {
        func pick(_ object: Any?, _ keys: [String: (Any) -> Bool]) -> [String: Any]? {
            guard let object = object as? [String: Any] else { return nil }
            return object.filter { key, value in keys[key]?(value) == true }
        }
        let text: (Any) -> Bool = { $0 is String }
        // A JSON number, not a boolean (both decode as NSNumber; a 0 exit code must stay).
        let number: (Any) -> Bool = { value in (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false }
        var page = pick(receipt, ["status": text, "exitCode": number, "timedOut": { $0 is Bool }, "reply": text,
                                  "cleanup": text]) ?? [:]
        if let timings = pick(receipt["timings"], ["totalMs": number, "bootMs": number]) { page["timings"] = timings }
        if let cost = pick(receipt["cost"], ["vmSeconds": number, "estimateUsd": number]) { page["cost"] = cost }
        if let artifacts = receipt["artifacts"] as? [Any] {
            page["artifacts"] = artifacts.compactMap { pick($0, ["name": text, "sizeBytes": number]) }
        }
        return page
    }

    /// The failure codes a Sandboxed reply may carry, the ones the page words (sandboxRun.ts
    /// `sandboxFailureKey`, `sandboxRetryable`): these, and the Run API's request refusals
    /// (``isRunRequestRefusal(_:)``). Any other code, such as one the server or a header sent that
    /// may name a provider handle, reaches the page as `unavailable` (a failure that may hide a live
    /// Run).
    static let sandboxCodes: Set<String> = [
        "labs_off", "not_signed_in", "cloud_disabled", "timeout", "unavailable", "unavailable_now", "bad_response",
        "sandbox_busy", "sandbox_spent", "run_sandbox_unavailable",
    ]

    static func isSandboxCode(_ code: String) -> Bool { sandboxCodes.contains(code) || isRunRequestRefusal(code) }

    /// The Run API's refusals of a request before it stores anything (`run_task_required`,
    /// `run_image_invalid`, `run_invalid_request`, …): lowercase words only, so no handle or id.
    public static func isRunRequestRefusal(_ code: String) -> Bool {
        if code == "run_invalid_request" { return true }
        let words = code.split(separator: "_", omittingEmptySubsequences: false)
        guard words.count >= 3, words.first == "run", words.last == "invalid" || words.last == "required" else { return false }
        return words.dropFirst().dropLast().allSatisfy { word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        }
    }

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
