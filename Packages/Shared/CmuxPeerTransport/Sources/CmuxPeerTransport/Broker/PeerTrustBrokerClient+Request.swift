import Foundation

/// The authenticated request pipeline: single-snapshot credential capture,
/// exactly-once 401 recovery, request signing, and error classification.
extension PeerTrustBrokerClient {
    func performRequest<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        // Build the request from ONE credential snapshot. Reading access then
        // refresh through two independent calls lets a force refresh land
        // between them and pair a stale access token with a rotated refresh
        // token, which the broker rejects.
        let capturedPair: PeerBrokerCredentials?
        do {
            capturedPair = try await tokenProvider.capture()
        } catch is CancellationError {
            // A cancelled caller must observe cancellation, not a retryable
            // network failure.
            throw CancellationError()
        } catch {
            // The source could not read a coherent pair right now (token store
            // mid-transition, re-mint in flight or offline). That is transient
            // and indistinguishable from an unreachable broker for every
            // caller policy, so classify it as connectivity, never as a
            // definitive authentication failure.
            throw PeerBrokerError.connectivity
        }
        guard let pair = capturedPair else {
            // Definitively signed out: fail closed without touching the wire.
            throw PeerBrokerError.unauthorized
        }
        do {
            return try await performAuthenticatedRequest(
                path: path,
                method: method,
                body: body,
                queryItems: queryItems,
                credentials: pair
            )
        } catch PeerBrokerError.unauthorized {
            // A pair that was coherent at capture can be rejected when another
            // lane rotated the session before the server validated it. Recover
            // ONCE with a pair minted after the rejection; a second rejection
            // is authoritative and propagates. Neither rejection clears any
            // cached transport state here.
            guard let recovered = try await recoveredCredentials(rejected: pair) else {
                throw PeerBrokerError.unauthorized
            }
            return try await performAuthenticatedRequest(
                path: path,
                method: method,
                body: body,
                queryItems: queryItems,
                credentials: recovered
            )
        }
    }

    /// One-shot credential recovery after a 401.
    ///
    /// Re-captures the pair first: if another lane already rotated the session
    /// (access token differs from the rejected one), that newer pair is reused
    /// without a refresh. Only an UNCHANGED rejected pair triggers exactly one
    /// `forceRefresh`, followed by one final capture. Any definitive absence
    /// returns nil so the original rejection propagates.
    private func recoveredCredentials(
        rejected: PeerBrokerCredentials
    ) async throws -> PeerBrokerCredentials? {
        var recaptured: PeerBrokerCredentials?
        do {
            recaptured = try await tokenProvider.capture()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A transient snapshot read can still be repaired by the one
            // explicit refresh below.
            recaptured = nil
        }
        if let recaptured, recaptured.accessToken != rejected.accessToken {
            return recaptured
        }
        do {
            try await tokenProvider.forceRefresh()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        do {
            return try await tokenProvider.capture()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func performAuthenticatedRequest<Response: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem],
        credentials: PeerBrokerCredentials
    ) async throws -> Response {
        guard PeerBrokerWire.isSafeHeaderValue(credentials.accessToken),
              PeerBrokerWire.isSafeHeaderValue(credentials.refreshToken) else {
            throw PeerBrokerError.unauthorized
        }
        let pathURL = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(
            url: pathURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw PeerBrokerError.protocolError
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw PeerBrokerError.protocolError
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credentials.refreshToken,
            forHTTPHeaderField: "X-Stack-Refresh-Token"
        )
        request.setValue(clientNamespace, forHTTPHeaderField: "X-Cmux-App-Namespace")
        if let bindingAuthorization,
           path != "api/devices/iroh/challenge",
           path != "api/devices/iroh/register" {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let signature = try bindingAuthorization.signer.signBrokerRequest(
                bindingID: bindingAuthorization.bindingID,
                method: method,
                path: path,
                timestamp: timestamp,
                body: body ?? Data()
            )
            request.setValue(
                bindingAuthorization.bindingID,
                forHTTPHeaderField: "X-Cmux-Iroh-Binding-ID"
            )
            request.setValue(
                String(timestamp),
                forHTTPHeaderField: "X-Cmux-Iroh-Request-Time"
            )
            request.setValue(
                signature,
                forHTTPHeaderField: "X-Cmux-Iroh-Request-Signature"
            )
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where Self.isConnectivityFailure(error.code) {
            throw PeerBrokerError.connectivity
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Every remaining local failure (TLS trust, size bounds, redirect
            // rejection) violates the fixed contract; fail closed.
            throw PeerBrokerError.protocolError
        }
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw PeerBrokerError.protocolError
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw Self.rejectionError(
                statusCode: http.statusCode,
                body: data,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(PeerBrokerWire.decodeISO8601)
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PeerBrokerError.protocolError
        }
    }

    private struct RejectionBody: Decodable {
        let error: String
    }

    private static func rejectionError(
        statusCode: Int,
        body: Data,
        retryAfterHeader: String?
    ) -> PeerBrokerError {
        if statusCode == 401 {
            return .unauthorized
        }
        if statusCode == 429 {
            return .serverRateLimited(
                retryAfter: retryAfterSeconds(retryAfterHeader).map(Duration.seconds)
            )
        }
        let code = try? JSONDecoder().decode(RejectionBody.self, from: body).error
        return .denied(statusCode: statusCode, code: code)
    }

    private static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let seconds = Int(value),
              (1 ... PeerBrokerWire.maximumRetryAfterSeconds).contains(seconds),
              String(seconds) == value else {
            return nil
        }
        return seconds
    }

    private static func isConnectivityFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .cannotLoadFromNetwork:
            true
        default:
            false
        }
    }
}
