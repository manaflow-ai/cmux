import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Type-safe client for the cmux API, generated from the checked-in OpenAPI
/// document via swift-openapi-generator.
public struct CmuxAPIClient: Sendable {
    /// Base path the API is mounted at; matches the OpenAPI `servers[0].url`.
    /// Append to an origin to build the `serverURL` this client expects.
    public static let apiServerPath = "/api/v1"

    private let client: Client

    /// Creates a client against `serverURL` with caller-supplied middlewares.
    /// - Parameters:
    ///   - serverURL: Origin plus ``apiServerPath`` (for example `https://cmux.io/api/v1`).
    ///   - transport: HTTP transport; defaults to `URLSessionTransport`.
    ///   - middlewares: Request middlewares applied in order.
    public init(
        serverURL: URL,
        transport: any ClientTransport = URLSessionTransport(),
        middlewares: [any ClientMiddleware] = []
    ) {
        self.client = Client(
            serverURL: serverURL,
            transport: transport,
            middlewares: middlewares
        )
    }

    /// Creates a client that authenticates every request with a Stack session.
    /// - Parameters:
    ///   - serverURL: Origin plus ``apiServerPath``.
    ///   - accessToken: Stack access token, sent as a bearer token.
    ///   - refreshToken: Stack refresh token, sent as `X-Stack-Refresh-Token`.
    ///   - transport: HTTP transport; defaults to `URLSessionTransport`.
    public init(
        serverURL: URL,
        accessToken: String,
        refreshToken: String,
        transport: any ClientTransport = URLSessionTransport()
    ) {
        self.init(
            serverURL: serverURL,
            transport: transport,
            middlewares: [
                StackAuthMiddleware(accessToken: accessToken, refreshToken: refreshToken),
            ]
        )
    }

    /// Fetches the authenticated account and its resolved billing plan.
    /// - Returns: The signed-in account's ``CmuxAccountPlan``.
    /// - Throws: ``CmuxAPIError/unauthorized`` on HTTP 401, or
    ///   ``CmuxAPIError/unexpectedStatus`` for any other unmodeled status.
    public func accountMe() async throws -> CmuxAccountPlan {
        let output = try await client.account_me()

        switch output {
        case .ok(let response):
            let body = try response.body.json
            return CmuxAccountPlan(
                userID: body.userId,
                email: body.email,
                planID: body.planId.rawValue,
                isPro: body.isPro,
                billingManagement: body.billingManagement.rawValue
            )
        case .undocumented(let statusCode, _):
            // requireAuth answers unauthenticated calls with 401; the RPC spec
            // documents only the 200 success shape, so it arrives undocumented.
            if statusCode == 401 { throw CmuxAPIError.unauthorized }
            throw CmuxAPIError.unexpectedStatus
        }
    }
}

/// Injects Stack access/refresh tokens onto every outbound request so the
/// server can resolve the signed-in user.
private struct StackAuthMiddleware: ClientMiddleware {
    private let accessToken: String
    private let refreshToken: String

    init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(accessToken)"
        request.headerFields[HTTPField.Name("X-Stack-Refresh-Token")!] = refreshToken
        return try await next(request, body, baseURL)
    }
}
