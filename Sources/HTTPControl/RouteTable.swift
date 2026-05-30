import Foundation

/// Table-driven HTTP route dispatcher used by ``HTTPControlServer``.
///
/// Patterns use `*` as a single path-segment wildcard. Method-mismatch
/// on a matched path returns 405 with the `Allow:` header populated
/// (D11). Unknown paths return 404 (D11 — indistinguishable from
/// `featureDisabled`).
///
/// The table is mutated only during setup; `dispatch(_:)` is `async`
/// because route handlers themselves are `async`.
public struct RouteTable: Sendable {
    /// Per-request handler signature. Handlers receive the parsed
    /// ``HTTPRequest`` and return the JSON response.
    public typealias Handler = @Sendable (HTTPRequest) async -> JSONResponses.Response

    private struct Route {
        let method: String
        let segments: [String]
        let handler: Handler
    }

    private var routes: [Route] = []

    /// Creates an empty table.
    public init() {}

    /// Registers a handler for `method` + `pattern`.
    ///
    /// - Parameters:
    ///   - method: HTTP method token (uppercase). Compared verbatim.
    ///   - pattern: Path pattern. Use `*` for a single-segment
    ///     wildcard (e.g. `/v1/surfaces/*/screen`).
    ///   - handler: Handler invoked when the request matches.
    public mutating func register(
        method: String,
        pattern: String,
        handler: @escaping Handler
    ) {
        routes.append(
            Route(method: method, segments: Self.split(pattern), handler: handler)
        )
    }

    /// Dispatches `req` to a registered handler.
    ///
    /// - Returns: The matched handler's response, a 405 with the
    ///   `Allow:` header for a path match with a wrong method (D11),
    ///   or a 404 with wire code `not_found` for an unknown path.
    public func dispatch(_ req: HTTPRequest) async -> JSONResponses.Response {
        let reqSegs = Self.split(req.path)
        var pathMatched: [String] = []
        for r in routes where Self.segmentsMatch(r.segments, reqSegs) {
            pathMatched.append(r.method)
        }
        guard !pathMatched.isEmpty else {
            // D11 — unknown path: same wire shape as featureDisabled.
            return JSONResponses.error(.featureDisabled)
        }
        for r in routes
        where r.method == req.method && Self.segmentsMatch(r.segments, reqSegs) {
            return await r.handler(req)
        }
        return JSONResponses.methodNotAllowed(allow: pathMatched)
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func segmentsMatch(_ pattern: [String], _ path: [String]) -> Bool {
        guard pattern.count == path.count else { return false }
        for (p, s) in zip(pattern, path) where p != "*" && p != s {
            return false
        }
        return true
    }
}
