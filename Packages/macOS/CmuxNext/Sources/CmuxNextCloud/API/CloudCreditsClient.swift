public import Foundation

/// Prepaid cmux credits on the cmux cloud API (backend credits-routes.ts), as the signed-in person:
/// read the balance, open a top-up's payment page, and ask the return page to grant a paid one.
/// The sign-in token comes from `token` per request and is never stored. Requests use
/// ``CloudAPIClient/noStoreTransport``, so no answer or header lands in a cache.
public nonisolated struct CloudCreditsClient: Sendable {
    /// The access token of the signed-in account; throws ``CloudCreditsError/notSignedIn`` when none.
    public typealias Token = @Sendable () async throws -> String

    /// The cloud API origin (`https://cloud-api.cmux.dev`, `https://cloud-api-staging.cmux.dev`).
    public let baseURL: URL
    let token: Token
    let session: URLSession

    /// - Parameters:
    ///   - baseURL: the cloud API origin.
    ///   - token: the signed-in account's access token.
    ///   - session: the transport; tests pass their own.
    public init(baseURL: URL, token: @escaping Token, session: URLSession = CloudAPIClient.noStoreTransport) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// `GET /v1/credits`.
    public func balance() async throws(CloudCreditsError) -> CloudCreditsBalance {
        try CloudCreditsBalance(json: try await send("GET", "/v1/credits"))
    }

    /// `POST /v1/credits/topup {usd}`: the payment page for `usd` dollars of credits.
    public func topUp(usd: Int) async throws(CloudCreditsError) -> URL {
        let data = try await send("POST", "/v1/credits/topup", body: ["usd": usd])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (object["value"] as? [String: Any])?["url"] as? String,
              let url = URL(string: raw), url.scheme?.lowercased() == "https" else { throw .badResponse }
        return url
    }

    /// `GET /v1/credits/checkout/done?session_id=`: the payment's return page, which grants a paid
    /// session at once (and only once; the webhook grants the same session under the same key).
    /// An unpaid session answers 202 and changes nothing, so this is safe to ask while waiting.
    public func grant(session checkout: String) async {
        var components = URLComponents(url: baseURL.appending(path: "v1/credits/checkout/done"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "session_id", value: checkout)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        _ = try? await session.data(for: request)
    }

    /// The Checkout session a payment page names in its path (`/c/pay/cs_test_…`); nil for another page.
    public static func checkoutSession(_ url: URL) -> String? {
        url.pathComponents.last { $0.hasPrefix("cs_") }
    }

    private func send(_ method: String, _ path: String, body: [String: any Sendable]? = nil) async throws(CloudCreditsError) -> Data {
        let access: String
        do { access = try await token() } catch let error as CloudCreditsError { throw error } catch { throw .notSignedIn }
        var request = URLRequest(url: baseURL.appending(path: String(path.dropFirst())), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw .transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            if http.statusCode == 401 { throw .notSignedIn }
            throw .http(status: http.statusCode, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        return data
    }
}
