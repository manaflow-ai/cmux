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
        case .decoding(let text): "unexpected response: \(text)"
        }
    }

    /// Parses the standard VM error body (`web/services/vms/routeHelpers.ts`
    /// `vmErrorResponse`: `{error, message, action, traceId, ui:{message, traceId}}`).
    static func from(status: Int, data: Data, headerCode: String?) -> CloudAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ui = object?["ui"] as? [String: Any]
        func text(_ value: Any?) -> String? {
            guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        return .http(status: status, code: headerCode ?? text(object?["error"]),
                     message: text(ui?["message"]) ?? text(object?["message"]),
                     action: text(object?["action"]), traceId: text(object?["traceId"]) ?? text(ui?["traceId"]))
    }
}
