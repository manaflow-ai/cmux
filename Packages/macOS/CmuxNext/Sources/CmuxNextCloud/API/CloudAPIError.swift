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
    /// A refusal cmux Pro lifts (`upgradeRequired`, no other plan named, not a
    /// credits purchase): a free account's create, the free access window, a Go
    /// plan's limits. `message` is the server's localized text; `upgradeURL` its
    /// cmux.com checkout or pricing link.
    case planRequired(message: String?, upgradeURL: URL?)
    case decoding(String)

    public var description: String {
        switch self {
        case .notSignedIn: "not signed in"
        case .noBackend(let url): "no Cloud backend at \(url.absoluteString)"
        case .timedOut(let path): "\(path) timed out"
        case .transport(let text): text
        case .http(let status, let code, let message): message ?? code ?? "HTTP \(status)"
        case .planRequired(let message, _): message ?? "Cloud machines need cmux Pro."
        case .decoding(let text): "unexpected response: \(text)"
        }
    }

    /// Parses the standard VM error body (`{error, message, ui:{message}}`);
    /// a refusal cmux Pro lifts is ``planRequired(message:upgradeURL:)``.
    static func from(status: Int, data: Data, headerCode: String?) -> CloudAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ui = object?["ui"] as? [String: Any]
        let message = (ui?["message"] as? String) ?? (object?["message"] as? String)
        let code = headerCode ?? (object?["error"] as? String)
        if let object, liftedByPro(object, code: code) { return .planRequired(message: message, upgradeURL: upgradeURL(object)) }
        return .http(status: status, code: code, message: message)
    }

    /// `upgradeRequired` (the server spreads `extra` to the top level) with no
    /// plan but Pro named: a Pro user's budget names Max, and a credits top-up
    /// is a purchase, not a plan (web/services/vms/routeHelpers.ts).
    private static func liftedByPro(_ object: [String: Any], code: String?) -> Bool {
        guard object["upgradeRequired"] as? Bool == true, code != "vm_create_credits_insufficient" else { return false }
        let plan = object["upgradePlanId"] as? String
        return plan == nil || plan == "pro"
    }

    /// The refusal's `upgradeUrl`, only an https cmux.com link.
    private static func upgradeURL(_ object: [String: Any]) -> URL? {
        guard let text = object["upgradeUrl"] as? String, let url = URL(string: text), url.scheme == "https",
              let host = url.host, host == "cmux.com" || host.hasSuffix(".cmux.com") else { return nil }
        return url
    }
}
