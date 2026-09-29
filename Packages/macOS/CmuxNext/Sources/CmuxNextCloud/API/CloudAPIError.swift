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
    case decoding(String)

    public var description: String {
        switch self {
        case .notSignedIn: "not signed in"
        case .noBackend(let url): "no Cloud backend at \(url.absoluteString)"
        case .timedOut(let path): "\(path) timed out"
        case .transport(let text): text
        case .http(let status, let code, let message): message ?? code ?? "HTTP \(status)"
        case .decoding(let text): "unexpected response: \(text)"
        }
    }

    /// Parses the standard VM error body (`{error, message, ui:{message}}`).
    static func from(status: Int, data: Data, headerCode: String?) -> CloudAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ui = object?["ui"] as? [String: Any]
        let message = (ui?["message"] as? String) ?? (object?["message"] as? String)
        let code = headerCode ?? (object?["error"] as? String)
        return .http(status: status, code: code, message: message)
    }
}
