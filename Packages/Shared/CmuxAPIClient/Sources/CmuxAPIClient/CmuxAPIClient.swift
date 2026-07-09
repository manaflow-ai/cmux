import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

public struct CmuxAccountPlan: Sendable, Hashable {
    public var userID: String
    /// Empty when the Stack user has no primary email.
    public var email: String
    public var planID: String
    public var isPro: Bool
    public var billingManagement: String

    public init(
        userID: String,
        email: String,
        planID: String,
        isPro: Bool,
        billingManagement: String
    ) {
        self.userID = userID
        self.email = email
        self.planID = planID
        self.isPro = isPro
        self.billingManagement = billingManagement
    }
}

public enum CmuxAPIError: Error, Sendable, Equatable {
    case unauthorized
    case unexpectedStatus
}

public struct CmuxAPIClient: Sendable {
    /// Base path the API is mounted at; matches the OpenAPI `servers[0].url`.
    /// Append to an origin to build the `serverURL` this client expects.
    public static let apiServerPath = "/api/v1"

    private let client: Client

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
