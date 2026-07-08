import CmuxAuthRuntime
import CmuxControlSocket
import Foundation

enum BillingClientError: Error {
    case notSignedIn
    case sessionRefreshFailed
    case malformedResponse(String)
    case backendUnreachable(url: String, detail: String)
}

actor BillingClient {
    @MainActor private(set) static var shared: BillingClient!

    @MainActor
    static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        let redirectSession = URLSession(
            configuration: .default,
            delegate: BillingNoRedirectDelegate(),
            delegateQueue: nil
        )
        shared = BillingClient(session: session, redirectSession: redirectSession, auth: auth)
    }

    private let session: URLSession
    private let redirectSession: URLSession
    private let auth: AuthCoordinator

    init(session: URLSession = .shared, redirectSession: URLSession, auth: AuthCoordinator) {
        self.session = session
        self.redirectSession = redirectSession
        self.auth = auth
    }

    func status() async -> JSONValue {
        do {
            let (data, http) = try await request("GET", path: "/api/billing/plan", followsRedirects: true)
            guard (200...299).contains(http.statusCode) else {
                return failure("http_status", source: sourceOrigin, status: http.statusCode, body: data)
            }
            let object = try decodeJSONValue(data)
            return .object([
                "source": .string(sourceOrigin),
                "plan": object,
            ])
        } catch let error as BillingClientError {
            return failure(error)
        } catch {
            return failure("request_failed", source: sourceOrigin, detail: String(describing: error))
        }
    }

    func checkout(plan: String) async -> JSONValue {
        await redirect(path: "/api/billing/checkout", queryItems: [
            URLQueryItem(name: "plan", value: plan),
        ])
    }

    func portal() async -> JSONValue {
        await redirect(path: "/api/billing/portal", queryItems: [])
    }

    private func redirect(path: String, queryItems: [URLQueryItem]) async -> JSONValue {
        do {
            let (data, http) = try await request("GET", path: path, queryItems: queryItems, followsRedirects: false)
            if (300...399).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location"),
               let url = URL(string: location, relativeTo: AuthEnvironment.apiBaseURL)?.absoluteURL {
                return redirectPayload(url)
            }
            if (200...299).contains(http.statusCode),
               let object = try? decodeJSONObject(data),
               let url = object["url"] as? String,
               !url.isEmpty {
                return .object(["ok": .bool(true), "source": .string(sourceOrigin), "url": .string(url)])
            }
            return failure("billing_unavailable", source: sourceOrigin, status: http.statusCode, body: data)
        } catch let error as BillingClientError {
            return failure(error)
        } catch {
            return failure("request_failed", source: sourceOrigin, detail: String(describing: error))
        }
    }

    private func request(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        followsRedirects: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens = try await currentTokens()
        guard var components = URLComponents(url: AuthEnvironment.apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw BillingClientError.malformedResponse("bad api base URL")
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw BillingClientError.malformedResponse("could not build URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")

        let activeSession = followsRedirects ? session : redirectSession
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await activeSession.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                throw BillingClientError.backendUnreachable(url: sourceOrigin, detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw BillingClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func currentTokens() async throws -> (accessToken: String, refreshToken: String) {
        do {
            return try await auth.currentTokens()
        } catch AuthError.networkError {
            throw BillingClientError.sessionRefreshFailed
        } catch {
            throw BillingClientError.notSignedIn
        }
    }

    private func redirectPayload(_ url: URL) -> JSONValue {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.path.hasSuffix("/pricing") || components.path.hasSuffix("/app-pricing") {
            let billing = components.queryItems?.first(where: { $0.name == "billing" })?.value
            let welcome = components.queryItems?.first(where: { $0.name == "welcome" })?.value
            if let billing, !billing.isEmpty {
                return .object([
                    "ok": .bool(false),
                    "source": .string(sourceOrigin),
                    "error": .string(billing),
                    "billing": .string(billing),
                ])
            }
            if welcome == "active" || welcome == "active-already-subscribed" {
                return .object([
                    "ok": .bool(false),
                    "source": .string(sourceOrigin),
                    "error": .string("active_already_subscribed"),
                    "welcome": .string(welcome ?? ""),
                ])
            }
            if let welcome, !welcome.isEmpty {
                return .object([
                    "ok": .bool(false),
                    "source": .string(sourceOrigin),
                    "error": .string(welcome),
                    "welcome": .string(welcome),
                ])
            }
            return .object([
                "ok": .bool(false),
                "source": .string(sourceOrigin),
                "error": .string("unavailable"),
            ])
        }
        return .object([
            "ok": .bool(true),
            "source": .string(sourceOrigin),
            "url": .string(url.absoluteString),
        ])
    }

    private func failure(_ error: BillingClientError) -> JSONValue {
        switch error {
        case .notSignedIn:
            return .object(["ok": .bool(false), "source": .string(sourceOrigin), "error": .string("not_signed_in")])
        case .sessionRefreshFailed:
            return .object(["ok": .bool(false), "source": .string(sourceOrigin), "error": .string("session_refresh_failed")])
        case let .malformedResponse(message):
            return .object([
                "ok": .bool(false),
                "source": .string(sourceOrigin),
                "error": .string("malformed_response"),
                "detail": .string(message),
            ])
        case let .backendUnreachable(_, detail):
            return .object([
                "ok": .bool(false),
                "source": .string(sourceOrigin),
                "error": .string("billing_unreachable"),
                "detail": .string(detail),
            ])
        }
    }

    private func failure(
        _ error: String,
        source: String,
        status: Int? = nil,
        body: Data? = nil,
        detail: String? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = ["ok": .bool(false), "source": .string(source), "error": .string(error)]
        if let status {
            payload["status"] = .int(Int64(status))
        }
        if let body, let serverError = serverErrorString(body), !serverError.isEmpty {
            payload["detail"] = .string(serverError)
        } else if let detail, !detail.isEmpty {
            payload["detail"] = .string(detail)
        }
        return .object(payload)
    }

    private func decodeJSONValue(_ data: Data) throws -> JSONValue {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let value = JSONValue(foundationObject: parsed) else {
            throw BillingClientError.malformedResponse("response is not valid JSON")
        }
        return value
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = parsed as? [String: Any] else {
            throw BillingClientError.malformedResponse("expected a JSON object")
        }
        return object
    }

    private func serverErrorString(_ data: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = parsed as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (object["error"] as? String) ?? (object["message"] as? String)
    }

    private var sourceOrigin: String {
        var components = URLComponents()
        components.scheme = AuthEnvironment.apiBaseURL.scheme
        components.host = AuthEnvironment.apiBaseURL.host
        components.port = AuthEnvironment.apiBaseURL.port
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? AuthEnvironment.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
