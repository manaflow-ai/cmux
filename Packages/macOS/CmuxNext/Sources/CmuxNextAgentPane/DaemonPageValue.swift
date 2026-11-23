public import CmuxNextDaemon
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// A value between a page and the session host (react-pages.md 1.1): params from the page's JSON
/// to the session host's, a result back, and a session host refusal as the page's error, its
/// code under `cmux.`.
public struct DaemonPageValue {
    public init() {}
    public static func daemonParams(_ members: [String: CmuxNextSettings.JSONValue]) throws -> [String: CmuxNextDaemon.JSONValue] {
        try JSONDecoder().decode([String: CmuxNextDaemon.JSONValue].self,
                                 from: Data(CmuxNextSettings.JSONValue.object(members).compactText.utf8))
    }

    public static func pageValue(_ value: CmuxNextDaemon.JSONValue) throws -> CmuxNextSettings.JSONValue {
        try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(value))
    }

    public static func pageError(_ error: DaemonError) -> PageError {
        switch error {
        case .command(_, let message, let code, let details, let retryable):
            let pageCode = code.map { $0.hasPrefix("cmux.") ? $0 : "cmux." + $0 } ?? "cmux.daemon.failed"
            return PageError(code: pageCode, message: message, retryable: retryable ?? false,
                             details: details.flatMap { try? pageValue($0) })
        case .notConnected, .connectionClosed, .daemonShutdown:
            return PageError(code: "cmux.protocol.closed", message: error.description, retryable: true)
        case .timedOut:
            return PageError(code: "cmux.protocol.timeout", message: error.description, retryable: true)
        default:
            return PageError(code: "cmux.daemon.failed", message: error.description)
        }
    }
}
