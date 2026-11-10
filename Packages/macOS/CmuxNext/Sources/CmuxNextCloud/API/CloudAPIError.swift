public import Foundation

/// A typed Cloud API failure (cmux-cloud-api `Failure`, one case for one, which reads every refusal). `message` is the server's display-safe text
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
}
