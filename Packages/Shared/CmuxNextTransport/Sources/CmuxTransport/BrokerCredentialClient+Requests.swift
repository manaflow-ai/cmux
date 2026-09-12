import Foundation

extension BrokerCredentialClient {
    /// The authenticated headers every broker request carries, resolved per
    /// mint so session-mode token rotation is always current.
    func authenticatedHeaders() async throws -> [String: String] {
        switch authentication {
        case .password(let stackBase, let projectId, let pck, let email, let password):
            let signIn = try await post(
                base: stackBase, path: "/api/v1/auth/password/sign-in",
                headers: [
                    "content-type": "application/json",
                    "x-stack-project-id": projectId,
                    "x-stack-publishable-client-key": pck,
                    "x-stack-access-type": "client",
                ],
                body: ["email": .string(email), "password": .string(password)],
                step: "stack sign-in")
            guard let access = signIn["access_token"]?.stringValue,
                let refresh = signIn["refresh_token"]?.stringValue
            else { throw BrokerError.shape("sign-in tokens") }
            return Self.authedHeaders(access: access, refresh: refresh)
        case .session(let tokens):
            guard let pair = try await tokens() else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.broker.error(
                        """
                        broker auth FAILED mode=session \
                        device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public) \
                        cause=not-signed-in (failing closed, no mint)
                        """)
                }
                throw BrokerError.notSignedIn
            }
            return Self.authedHeaders(
                access: pair.accessToken, refresh: pair.refreshToken)
        }
    }

    private static func authedHeaders(
        access: String, refresh: String
    ) -> [String: String] {
        [
            "content-type": "application/json",
            "authorization": "Bearer \(access)",
            "x-stack-refresh-token": refresh,
        ]
    }

    func post(
        base: String, path: String, headers: [String: String], body: [String: JSONValue], step: String
    ) async throws -> [String: JSONValue] {
        let requestUrl = try Self.originURL(base: base, path: path, step: step)
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = Self.serverErrorCode(in: data)
            if TransportDebugLog.enabled {
                TransportDebugLog.broker.error(
                    """
                    broker step FAILED step=\(step, privacy: .public) \
                    status=\(status, privacy: .public) \
                    path=\(requestUrl.path, privacy: .public) \
                    error=\(code ?? "unparsed", privacy: .public) \
                    device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public)
                    """)
            }
            throw BrokerError.http(
                step: step, status: status, path: requestUrl.path, code: code)
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.broker.notice(
                """
                broker step ok step=\(step, privacy: .public) \
                status=\(status, privacy: .public) \
                device=\(TransportDebugLog.prefix(self.deviceId), privacy: .public)
                """)
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
    }

    /// Plain HTTP is safe only for an explicitly loopback broker. A remote
    /// `http://` origin would place bearer/refresh or password credentials on
    /// the wire without transport encryption.
    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    /// Builds a request URL from a clean origin and a fixed API path. Query,
    /// fragment, userinfo, and embedded base paths are rejected so caller
    /// configuration cannot redirect authenticated requests or expose URL
    /// credentials.
    private static func originURL(base: String, path: String, step: String) throws -> URL {
        guard let baseURL = URL(string: base),
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            let host = components.host,
            scheme == "https" || isLoopbackHost(host),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            path.hasPrefix("/"),
            !path.contains("?") && !path.contains("#")
        else {
            throw BrokerError.malformedURL(step: step, url: diagnosticOrigin(base))
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw BrokerError.malformedURL(step: step, url: diagnosticOrigin(base))
        }
        return url
    }

    /// Validates broker-issued relay credentials before exposing them to an
    /// endpoint. Every token must be endpoint-bound to this identity and every
    /// relay origin must be a clean encrypted (or explicit loopback) URL.
    func validatedCredentials(_ credentials: [Credential]) throws -> [Credential] {
        guard !credentials.isEmpty, credentials.count <= 32 else {
            throw BrokerError.shape("relay credential count")
        }
        let now = Int64(Date().timeIntervalSince1970)
        var seenURLs = Set<String>()
        var validated: [Credential] = []
        validated.reserveCapacity(credentials.count)
        for credential in credentials {
            let knownExpiries = [
                credential.expiresAt,
                IrohSubstrate().tokenExpiry(credential.token),
            ].compactMap { $0 }
            guard let url = URL(string: credential.relayUrl),
                let scheme = url.scheme?.lowercased(),
                let host = url.host,
                (scheme == "https" || (scheme == "http" && Self.isLoopbackHost(host))),
                url.user == nil,
                url.password == nil,
                url.query == nil,
                url.fragment == nil,
                !credential.token.isEmpty,
                credential.token.utf8.count <= 16 * 1024,
                IrohSubstrate().tokenEndpointId(credential.token) == identity.publicKeyData,
                knownExpiries.allSatisfy({ $0 > now }),
                seenURLs.insert(credential.relayUrl).inserted
            else {
                throw BrokerError.shape("invalid relay credential")
            }
            validated.append(credential)
        }
        return validated
    }

    static let alreadyBoundCode = "endpoint_already_bound"

    /// Logs only an origin; malformed inputs, credentials, paths and URL
    /// suffixes never escape into diagnostics even before validation.
    static func diagnosticOrigin(_ value: String) -> String {
        guard let source = URLComponents(string: value),
            let scheme = source.scheme, ["https", "http"].contains(scheme.lowercased()),
            let host = source.host, !host.isEmpty
        else { return "<invalid-origin>" }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = source.port
        return origin.string ?? "<invalid-origin>"
    }

    /// The short stable error code from a broker error body. The broker
    /// always answers `{"error": <code>}` (web/services/iroh/
    /// routeHandler.ts); the code is still server-controlled text, so
    /// anything long or outside the code alphabet is dropped rather than
    /// propagated into errors and logs.
    static func serverErrorCode(in data: Data) -> String? {
        if let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
            let code = object["error"]?.stringValue, Self.isSafeErrorCode(code)
        {
            return code
        }
        // Last-resort fallback for a non-JSON body (a proxy error page, a
        // legacy broker): the one code the mint flow must still recognize
        // is endpoint_already_bound, so scan for exactly that token.
        if let text = String(data: data, encoding: .utf8),
            text.contains(Self.alreadyBoundCode)
        {
            return Self.alreadyBoundCode
        }
        return nil
    }

    private static func isSafeErrorCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= 64 else { return false }
        return code.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
        }
    }

    /// Uses the earliest known broker or JWT expiry: a broker timestamp
    /// cannot extend the token's relay-enforced lifetime. Unknown deadlines
    /// retain the scheduler's fallback cadence only when neither is visible.
    static func credential(
        relayUrl: String, token: String, serverExpiresAt: Int64?
    ) -> Credential {
        Credential(
            relayUrl: relayUrl, token: token,
            expiresAt: [serverExpiresAt, IrohSubstrate().tokenExpiry(token)]
                .compactMap { $0 }.min())
    }

    /// Epoch seconds from the broker's ISO-8601 timestamps
    /// (`Date.toISOString()` emits fractional seconds; tolerate both).
    static func epochSeconds(iso8601 value: String) -> Int64? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return Int64(date.timeIntervalSince1970)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value).map { Int64($0.timeIntervalSince1970) }
    }

    func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
