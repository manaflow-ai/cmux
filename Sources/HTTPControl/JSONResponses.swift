import CmuxTerminalAccess
import Foundation

/// Single source of truth for building HTTP responses from the cmux
/// control transport.
///
/// Centralises the spec §12 status mapping and the locked decisions
/// D11 (`featureDisabled` → 404) and D18 (`unsupported` → 415) so the
/// router never picks a divergent status. All bodies are emitted as
/// JSON with sorted keys for deterministic snapshot tests.
public enum JSONResponses {
    /// Concrete HTTP response value: status line plus headers plus
    /// pre-encoded body bytes. The router serialises this onto the
    /// wire verbatim.
    public struct Response: Equatable {
        /// Numeric HTTP status code (e.g. 200, 404, 415).
        public let status: Int
        /// Response headers in the order they should be emitted.
        /// `Content-Type` and `Content-Length` are populated by the
        /// builder for JSON bodies; `Allow` is populated for 405.
        public let headers: [(String, String)]
        /// Response body bytes; UTF-8 JSON for every response built
        /// here.
        public let body: Data

        public init(status: Int, headers: [(String, String)], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func == (lhs: Response, rhs: Response) -> Bool {
            guard
                lhs.status == rhs.status,
                lhs.body == rhs.body,
                lhs.headers.count == rhs.headers.count
            else { return false }
            for (l, r) in zip(lhs.headers, rhs.headers) where l != r {
                return false
            }
            return true
        }
    }

    /// Encodes `object` as JSON and wraps it as a ``Response`` with
    /// the given status and `Content-Type: application/json`.
    ///
    /// - Parameters:
    ///   - status: HTTP status code.
    ///   - object: JSON-serialisable object (typically a dictionary
    ///     or array of dictionaries).
    ///   - extraHeaders: Additional headers prepended before the
    ///     content headers.
    public static func json(
        _ status: Int,
        _ object: Any,
        extraHeaders: [(String, String)] = []
    ) -> Response {
        let body = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        var headers = extraHeaders
        headers.append(("Content-Type", "application/json"))
        headers.append(("Content-Length", "\(body.count)"))
        return Response(status: status, headers: headers, body: body)
    }

    /// Returns the HTTP status code that ``error(_:)`` will use for
    /// `error`. Mirrors ``TerminalAccessError/httpStatus`` so the
    /// transport stays in lockstep with the domain model.
    public static func status(for error: TerminalAccessError) -> Int {
        error.httpStatus
    }

    /// Builds the JSON error envelope for `error`. The body shape is
    /// `{"error": {"code": "...", "message": "..."}}` per spec §13.
    public static func error(_ error: TerminalAccessError) -> Response {
        json(
            status(for: error),
            ["error": ["code": error.wireCode, "message": error.message]]
        )
    }

    /// 405 Method Not Allowed with the `Allow:` header populated per
    /// D11. The router calls this when the path matches but the
    /// method does not.
    ///
    /// - Parameter allow: Permitted methods in the desired display
    ///   order (e.g. `["GET", "POST"]`).
    public static func methodNotAllowed(allow: [String]) -> Response {
        json(
            405,
            ["error": ["code": "method_not_allowed", "message": "Method not allowed"]],
            extraHeaders: [("Allow", allow.joined(separator: ", "))]
        )
    }
}
