public import Foundation

/// A typed `/api/vm` failure. `message` is the server's display-safe text
/// (`ui.message` / `message`) when it sent one, `action` its next step
/// ("Run `…`") and `traceId` the support reference a person pastes.
public enum CloudAPIError: Error, Sendable, Equatable, CustomStringConvertible {
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
    /// (the app passes its localized "(trace %@)").
    public func text(trace: (String) -> String = { "(trace \($0))" }) -> String {
        switch self {
        case .notSignedIn: "not signed in"
        case .noBackend(let url): "no Cloud backend at \(url.absoluteString)"
        case .timedOut(let path): "\(path) timed out"
        case .transport(let text): text
        case .http(let status, let code, let message, let action, let traceId):
            [message ?? code ?? "HTTP \(status)", action, traceId.map(trace)].compactMap { $0 }.joined(separator: " ")
        case .planRequired(let message, _, let plan): message ?? (plan == "pro" ? "Cloud machines need cmux Pro." : "This needs cmux \(plan.capitalized).")
        case .decoding(let text): "unexpected response: \(text)"
        }
    }

    /// A stable code for a caller that maps failures to its own text: the server's error code
    /// (`run_sandbox_unavailable`, …) when it sent one. Server text: a caller that hands it on
    /// past the app keeps only the codes it knows.
    public var code: String {
        switch self {
        case .notSignedIn: "not_signed_in"
        case .noBackend, .transport: "unavailable"
        case .timedOut: "timeout"
        case .http(let status, let code, _, _, _): code ?? "http_\(status)"
        case .planRequired: "plan_required"
        case .decoding: "bad_response"
        }
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
        let code = headerCode ?? text(object?["error"])
        let message = text(ui?["message"]) ?? text(object?["message"])
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
