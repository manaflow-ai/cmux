public import CmuxNextSettings
public import Foundation

/// The App Store registry on the API Worker (`/v1/apps/registry/`, backend
/// app-registry-routes.ts; custom-panes-DESIGN.md section 6.3). Listings and
/// approved bundles are public; the rest go with the person's own session.
/// Nothing is cached, no cookie is kept, no redirect is followed, nothing is
/// retried. A refusal throws a ``PageError`` with the registry's code; no
/// session, or one the Worker does not accept, is `cloud.signed_out`.
public nonisolated struct AppRegistryAPI: Sendable {
    public typealias AccessToken = @Sendable () async throws -> String

    public static let signedOut = PageError(code: "cloud.signed_out", message: "Sign in to cmux Cloud to use the App Store community.")

    let baseURL: URL
    let accessToken: AccessToken
    let session: URLSession

    public init(baseURL: URL, accessToken: @escaping AccessToken, session: URLSession = Self.makeSession()) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    /// One call: `path` under the registry prefix, with `query` items, a JSON `body`, and the
    /// person's bearer when `signed`.
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil,
                 signed: Bool = true) async throws(PageError) -> JSONValue {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let base = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [base, "v1/apps/registry", path].filter { !$0.isEmpty }.joined(separator: "/")
        components?.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw PageError.invalidParams("bad registry path") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if signed {
            let access: String
            do { access = try await accessToken() } catch { throw Self.signedOut }
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body.foundationObject)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PageError(code: "registry.unreachable", message: "The App Store could not be reached.", retryable: true)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = try? JSONValue.parse(data)
        guard (200..<300).contains(status), let value else {
            if status == 401 { throw Self.signedOut }
            let error = value?["error"]
            throw PageError(code: error?["code"]?.stringValue ?? "registry.failed",
                            message: error?["message"]?.stringValue ?? "The App Store answered \(status).",
                            retryable: status >= 500)
        }
        return value
    }

    /// No cache, no cookies, and redirects refused: the session bearer never follows one. One per
    /// App Store page (its provider owns it), not a shared global.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private nonisolated final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
