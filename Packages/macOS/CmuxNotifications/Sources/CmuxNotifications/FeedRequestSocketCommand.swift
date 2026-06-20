public import Foundation

/// A single V2 control-socket command the notification feed dispatches: a
/// JSON-RPC `{ "id", "method", "params" }` envelope whose params are all string
/// values (workspace/surface ids and free text). Mirrors the inline payload the
/// legacy `handleFeedRequestFocus`/`handleFeedRequestSendText` built with
/// `JSONSerialization.data(withJSONObject:)`, but stays typed so the package
/// carries no `Any`.
///
/// `id` is a fresh `UUID().uuidString` per command, matching the legacy code
/// (the in-process handler echoes the id back but the feed ignores the result,
/// so the value is never compared). `jsonLine()` renders the compact,
/// non-pretty, unescaped-slash line the socket handler re-parses; since the
/// receiver decodes the JSON rather than byte-matching it, this is wire-faithful
/// to the legacy `JSONSerialization` output for these string-only payloads.
public struct FeedRequestSocketCommand: Sendable, Equatable {
    /// The V2 method name (for example `"surface.focus"`).
    public let method: String
    /// The command's string-valued parameters (for example `["surface_id": …]`).
    public let params: [String: String]

    /// Creates a feed socket command.
    public init(method: String, params: [String: String]) {
        self.method = method
        self.params = params
    }

    private struct Envelope: Encodable {
        let id: String
        let method: String
        let params: [String: String]
    }

    /// Renders the newline-free JSON-RPC line for ``FeedRequestSocketLineInvoking``,
    /// stamping a fresh request id. Returns `nil` only if encoding fails, matching
    /// the legacy `try?`/`guard let` chain that silently dropped an unencodable
    /// payload (unreachable for string-only params).
    public func jsonLine(id: String = UUID().uuidString) -> String? {
        let envelope = Envelope(id: id, method: method, params: params)
        guard let data = try? JSONEncoder().encode(envelope),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line
    }
}
