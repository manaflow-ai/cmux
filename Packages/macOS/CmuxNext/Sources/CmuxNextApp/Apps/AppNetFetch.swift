import CmuxNextApps
import Foundation

/// `cmux.net.fetch` for the DEV prototype engine. The engine admitted the
/// URL against the app's `net:` scopes; this strips credentials an app
/// could smuggle (Authorization, Cookie, Proxy-Authorization), never
/// stores cookies or caches, caps the body at 2 MiB, and drops Set-Cookie
/// from the response. The supervisor's egress gate (spec section 10)
/// replaces it.
nonisolated final class AppNetFetch: Sendable {
    static let maxBody = 2 * 1024 * 1024
    static let strippedHeaders: Set<String> = ["authorization", "cookie", "proxy-authorization"]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    static func request(_ params: AppJSON) throws -> URLRequest {
        guard let text = params["url"]?.stringValue, let url = URL(string: text), url.scheme?.lowercased() == "https" else {
            throw AppOperationError(code: "invalid_params", message: "net.fetch needs an https url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = (params["method"]?.stringValue ?? "GET").uppercased()
        for (name, value) in params["headers"]?.objectValue ?? [:] where !strippedHeaders.contains(name.lowercased()) {
            if let value = value.stringValue { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let body = params["body"]?.stringValue { request.httpBody = Data(body.utf8) }
        return request
    }

    func fetch(_ params: AppJSON) async throws -> AppJSON {
        let request = try Self.request(params)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppOperationError(code: "net.failed", message: "no HTTP response") }
        guard data.count <= Self.maxBody else { throw AppOperationError(code: "app.limit", message: "response over 2 MiB", details: ["limit": "fetchBody"]) }
        var headers: [String: AppJSON] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, name.lowercased() != "set-cookie" else { continue }
            headers[name.lowercased()] = .string(String(describing: value))
        }
        return ["status": .number(Double(http.statusCode)), "headers": .object(headers), "body": .string(String(decoding: data, as: UTF8.self))]
    }
}
