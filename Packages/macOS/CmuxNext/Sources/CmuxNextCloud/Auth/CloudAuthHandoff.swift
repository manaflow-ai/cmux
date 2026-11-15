import CmuxAuthRuntime
public import Foundation

/// cmux-api's sign-in hand-off (`backend/apps/api/src/auth-handoff.ts`), for `cmux auth handoff`:
/// this app mints a one-time code with its own human Stack session, and the app on another Mac of
/// the same person redeems it for a new session of that user. Only HTTP and decoding live here; the
/// rules (single use, two minutes, rate limit, SSO, audit) are the server's, and the CLI is Rust.
///
/// ```swift
/// let api = CloudAuthHandoff(apiOrigin: configuration.ownerAPIBaseURL())
/// let minted = try await auth.mintHandoff(device: "air-blue", api: api)
/// ```
public struct CloudAuthHandoff: Sendable {
    /// One HTTP exchange; tests replace it.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// A minted code. `expiresAt` is Unix milliseconds.
    public struct Minted: Sendable, Equatable, CustomStringConvertible {
        public let code: String
        public let expiresAt: Int64
        public let user: String
        public let email: String?
        public let device: String?

        public init(code: String, expiresAt: Int64, user: String, email: String?, device: String?) {
            self.code = code
            self.expiresAt = expiresAt
            self.user = user
            self.email = email
            self.device = device
        }

        public var description: String { "CloudAuthHandoff.Minted(user: \(user), code redacted)" }
    }

    /// A redeemed code: a new session (both tokens), or `alreadySignedIn` (this app is signed in as
    /// that user already; the code is spent and no session was made).
    public struct Redeemed: Sendable, CustomStringConvertible {
        public let alreadySignedIn: Bool
        public let accessToken: String?
        public let refreshToken: String?
        /// The platform user id (`user_…`).
        public let user: String
        public let stackUser: String
        public let email: String?
        public let device: String?

        public init(alreadySignedIn: Bool, accessToken: String?, refreshToken: String?, user: String, stackUser: String, email: String?, device: String?) {
            self.alreadySignedIn = alreadySignedIn
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.user = user
            self.stackUser = stackUser
            self.email = email
            self.device = device
        }

        public var description: String { "CloudAuthHandoff.Redeemed(user: \(user), already: \(alreadySignedIn), tokens redacted)" }
    }

    /// Why there is no code or session, as the socket error code the CLI maps to its exit code:
    /// `handoff_invalid`, `other_user`, `not_signed_in`, `sso_required`, `rate_limited`,
    /// `invalid_params` or `unavailable`.
    public struct Refusal: Error, Sendable, Equatable {
        public let code: String
        public init(code: String) { self.code = code }
    }

    let apiOrigin: URL
    let send: Send

    public init(apiOrigin: URL, send: @escaping Send = { try await CloudAPIClient.noStoreTransport.data(for: $0) }) {
        self.apiOrigin = apiOrigin
        self.send = send
    }

    /// POST /v1/auth/handoffs with the app's Stack access token.
    public func mint(stackAccessToken: String, device: String?) async throws -> Minted {
        var body: [String: Any] = [:]
        if let device { body["device"] = device }
        let object = try await post("v1/auth/handoffs", body: body, bearer: stackAccessToken)
        guard let code = object["code"] as? String, let expires = (object["expires_at"] as? NSNumber)?.int64Value,
              let user = object["user"] as? String else { throw Refusal(code: "unavailable") }
        return Minted(code: code, expiresAt: expires, user: user, email: object["email"] as? String, device: object["device"] as? String)
    }

    /// POST /v1/auth/handoffs/redeem. `expectedUser` is the Stack user id this app is signed in as now.
    public func redeem(code: String, device: String?, expectedUser: String?) async throws -> Redeemed {
        var body: [String: Any] = ["code": code]
        if let device { body["device"] = device }
        if let expectedUser { body["expected_user"] = expectedUser }
        let object = try await post("v1/auth/handoffs/redeem", body: body, bearer: nil)
        guard let user = object["user"] as? String, let stackUser = object["stack_user"] as? String else { throw Refusal(code: "unavailable") }
        let already = object["already_signed_in"] as? Bool ?? false
        let access = object["access_token"] as? String, refresh = object["refresh_token"] as? String
        if !already, access?.isEmpty != false || refresh?.isEmpty != false { throw Refusal(code: "unavailable") }
        return Redeemed(alreadySignedIn: already, accessToken: access, refreshToken: refresh, user: user, stackUser: stackUser,
                        email: object["email"] as? String, device: object["device"] as? String)
    }

    /// The socket code for cmux-api's error `code` (auth-handoff-routes.ts).
    static func refusalCode(server code: String?) -> String {
        switch code {
        case "auth_handoff.invalid": "handoff_invalid"
        case "auth_handoff.other_user": "other_user"
        case "auth.sso_required": "sso_required"
        case "auth_handoff.rate_limited": "rate_limited"
        case "auth_handoff.human_session_required", "auth.unauthenticated", "auth_handoff.no_account": "not_signed_in"
        case "validation.invalid": "invalid_params"
        default: "unavailable"
        }
    }

    private func post(_ path: String, body: [String: Any], bearer: String?) async throws -> [String: Any] {
        var request = URLRequest(url: apiOrigin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw Refusal(code: "unavailable")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else {
            throw Refusal(code: Self.refusalCode(server: (object["error"] as? [String: Any])?["code"] as? String))
        }
        return object
    }
}

extension CloudAuth {
    /// `auth.handoff.mint`: a one-time code for another Mac of this person, minted with this app's own
    /// human Stack session (never an install token). Throws ``CloudAuthHandoff/Refusal``.
    public func mintHandoff(device: String?, api: CloudAuthHandoff) async throws -> CloudAuthHandoff.Minted {
        guard await restoredAccessToken() != nil, let access = try? await tokens().access else {
            throw CloudAuthHandoff.Refusal(code: "not_signed_in")
        }
        return try await api.mint(stackAccessToken: access, device: device)
    }

    /// `auth.handoff.redeem`: redeems `code` and signs this app in with the new session, through the
    /// browser sign-in's own completion (``HostBrowserSignInFlow/completeHandoff(accessToken:refreshToken:)``).
    /// Signed in as another account: refused (`other_user`), the code unspent. Throws ``CloudAuthHandoff/Refusal``.
    public func redeemHandoff(code: String, device: String?, api: CloudAuthHandoff) async throws -> CloudAuthHandoff.Redeemed {
        await awaitRestored()
        let current = isSignedIn ? user?.id : nil
        let redeemed = try await api.redeem(code: code, device: device, expectedUser: current)
        if redeemed.alreadySignedIn { return redeemed }
        guard let access = redeemed.accessToken, let refresh = redeemed.refreshToken,
              await browserSignIn.completeHandoff(accessToken: access, refreshToken: refresh) else {
            throw CloudAuthHandoff.Refusal(code: "unavailable")
        }
        return redeemed
    }
}
