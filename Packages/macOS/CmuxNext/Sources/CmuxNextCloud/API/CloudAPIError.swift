public import Foundation

/// A typed `/api/vm` failure. `message` is the server's display-safe text
/// (`ui.message` / `message`) when it sent one, `action` its next step
/// ("Run `…`") and `traceId` the support reference a person pastes.
public enum CloudAPIError: Error, Sendable, Equatable, Codable, CustomStringConvertible {
    case notSignedIn
    /// The build points at a loopback origin with no server (local backend mode).
    case noBackend(URL)
    case timedOut(String)
    case transport(String)
    case http(status: Int, code: String?, message: String?, action: String? = nil, traceId: String? = nil)
    /// A refusal a paid plan lifts (`upgradeRequired`, not a credits purchase):
    /// `plan` is the plan that lifts it, `pro` (a free account's create, the free
    /// access window, a Go plan's limits) or `max` (a Pro plan's compute budget,
    /// pool or locked size). `message` is the server's localized text;
    /// `upgradeURL` its cmux.com checkout or pricing link.
    case planRequired(message: String?, upgradeURL: URL?, plan: String = "pro")
    case decoding(String)

    public var description: String { text() }

    /// The text a person reads. An HTTP failure reads as the server's
    /// message, then its next step, then the trace id as `trace` writes it
    /// (the app passes its localized "(trace %@)"). Worded by cmux-cloud-machine `error.rs`.
    public func text(trace: (String) -> String = { "(trace \($0))" }) -> String {
        words(trace: trace("%@"))?.text ?? "unexpected response"
    }

    /// A stable code for a caller that maps failures to its own text: the server's error code
    /// (`run_sandbox_unavailable`, …) when it sent one. Server text: a caller that hands it on
    /// past the app keeps only the codes it knows.
    public var code: String { words(trace: "(trace %@)")?.code ?? "bad_response" }

    private struct Words: Decodable { var text: String, code: String }

    private func words(trace: String) -> Words? {
        struct Request: Encodable { var error: CloudAPIError, traceFormat: String }
        return CloudMachineRules().call("cloud_model_api_error_text", Request(error: self, traceFormat: trace), as: Words.self)
    }

    /// Parses the standard VM error body (`web/services/vms/routeHelpers.ts`
    /// `vmErrorResponse`: `{error, message, action, traceId, ui:{message, traceId}}`);
    /// a refusal a paid plan lifts is ``planRequired(message:upgradeURL:plan:)``.
    static func from(status: Int, data: Data, headerCode: String?) -> CloudAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ui = object?["ui"] as? [String: Any]
        func text(_ value: Any?) -> String? {
            guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        // The cmux API Worker nests its refusal: `{ok: false, error: {code, message}}`.
        let nested = object?["error"] as? [String: Any]
        let code = headerCode ?? text(object?["error"]) ?? text(nested?["code"])
        let message = text(ui?["message"]) ?? text(object?["message"]) ?? text(nested?["message"])
        if let object, let plan = liftingPlan(object, code: code) {
            return .planRequired(message: message, upgradeURL: upgradeURL(object), plan: plan)
        }
        return .http(status: status, code: code, message: message,
                     action: text(object?["action"]), traceId: text(object?["traceId"]) ?? text(ui?["traceId"]))
    }

    /// The plan an `upgradeRequired` refusal names (the server spreads `extra`
    /// to the top level): `upgradePlanId`, else `pro`; nil for a plan cmux does
    /// not sell here, and for a credits top-up, a purchase rather than a plan
    /// (web/services/vms/routeHelpers.ts).
    private static func liftingPlan(_ object: [String: Any], code: String?) -> String? {
        guard object["upgradeRequired"] as? Bool == true, code != "vm_create_credits_insufficient" else { return nil }
        let plan = (object["upgradePlanId"] as? String) ?? "pro"
        return plan == "pro" || plan == "max" ? plan : nil
    }

    /// The refusal's `upgradeUrl`, only an https cmux.com link.
    private static func upgradeURL(_ object: [String: Any]) -> URL? {
        guard let text = object["upgradeUrl"] as? String, let url = URL(string: text), url.scheme == "https",
              let host = url.host, host == "cmux.com" || host.hasSuffix(".cmux.com") else { return nil }
        return url
    }
}
