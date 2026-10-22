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
    /// The account's plan includes no Cloud machine (`upgradeRequired` on the
    /// refusal, e.g. a free account's create): cmux Pro lifts it.
    case planRequired(message: String?)
    case decoding(String)

    public var description: String {
        switch self {
        case .notSignedIn: "not signed in"
        case .noBackend(let url): "no Cloud backend at \(url.absoluteString)"
        case .timedOut(let path): "\(path) timed out"
        case .transport(let text): text
        case .http(let status, let code, let message): message ?? code ?? "HTTP \(status)"
        case .planRequired(let message): message ?? "Cloud machines need cmux Pro."
        case .decoding(let text): "unexpected response: \(text)"
        }
    }

    /// Parses the standard VM error body (`{error, message, ui:{message}}`);
    /// a refusal that sets `upgradeRequired` (top level, `extra` or `details`)
    /// is ``planRequired(message:)``.
    static func from(status: Int, data: Data, headerCode: String?) -> CloudAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ui = object?["ui"] as? [String: Any]
        let message = (ui?["message"] as? String) ?? (object?["message"] as? String)
        let flags = [object, object?["extra"] as? [String: Any], object?["details"] as? [String: Any]]
        if flags.contains(where: { $0?["upgradeRequired"] as? Bool == true }) { return .planRequired(message: message) }
        let code = headerCode ?? (object?["error"] as? String)
        return .http(status: status, code: code, message: message)
    }
}
