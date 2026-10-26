public import Foundation

/// A typed `/api/vm` failure. `message` is the server's display-safe text
/// (`ui.message` / `message`) when it sent one.
public enum CloudAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    case notSignedIn
    /// The build points at a loopback origin with no server (local backend mode).
    case noBackend(URL)
    case timedOut(String)
    case transport(String)
    case http(status: Int, code: String?, message: String?)
    /// A refusal a paid plan lifts (`upgradeRequired`, not a credits purchase):
    /// `plan` is the plan that lifts it, `pro` (a free account's create, the free
    /// access window, a Go plan's limits) or `max` (a Pro plan's compute budget,
    /// pool or locked size). `message` is the server's localized text;
    /// `upgradeURL` its cmux.com checkout or pricing link.
    case planRequired(message: String?, upgradeURL: URL?, plan: String = "pro")
    case decoding(String)

    public var description: String {
        switch self {
        case .notSignedIn: "not signed in"
        case .noBackend(let url): "no Cloud backend at \(url.absoluteString)"
        case .timedOut(let path): "\(path) timed out"
        case .transport(let text): text
        case .http(let status, let code, let message): message ?? code ?? "HTTP \(status)"
        case .planRequired(let message, _, let plan): message ?? (plan == "pro" ? "Cloud machines need cmux Pro." : "This needs cmux \(plan.capitalized).")
        case .decoding(let text): "unexpected response: \(text)"
        }
    }

    /// Parses the standard VM error body (`{error, message, ui:{message}}`);
    /// a refusal a paid plan lifts is ``planRequired(message:upgradeURL:plan:)``.
    static func from(status: Int, data: Data, headerCode: String?) -> CloudAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ui = object?["ui"] as? [String: Any]
        let message = (ui?["message"] as? String) ?? (object?["message"] as? String)
        let code = headerCode ?? (object?["error"] as? String)
        if let object, let plan = liftingPlan(object, code: code) {
            return .planRequired(message: message, upgradeURL: upgradeURL(object), plan: plan)
        }
        return .http(status: status, code: code, message: message)
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
