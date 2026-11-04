import Foundation

/// The signed-in account's own Cloud calls beyond the Chief conversation: Automations
/// (`automation.*` over `/v1/read` and `/v1/ops`), Connect GitHub (`integration.*`) and the synced
/// Artifacts (the platform's `/v1/artifacts` reads). Every call carries this phone's own access
/// token, as the Chief's do; nothing goes through a Mac or the relay.
public struct AccountCloud: Sendable {
    /// Why a call did not answer, in the service's words where it gave them.
    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        case refused(status: Int, code: String, message: String)
        case unreachable
        case badReply

        public var description: String {
            switch self {
            case let .refused(_, code, message): message.isEmpty ? code : message
            case .unreachable: String(localized: "Couldn't reach cmux Cloud. Check your connection.")
            case .badReply: String(localized: "cmux Cloud answered something the phone can't read.")
            }
        }

        public var code: String? {
            if case let .refused(_, code, _) = self { return code }
            return nil
        }
    }

    /// One platform read's answer (`/v1/artifacts/file` carries the bytes and their type).
    public struct PlatformReply: Sendable {
        public var status: Int
        public var body: Data
        public var contentType: String?
        /// `X-Artifacts-Commit`: the commit a file read resolved to.
        public var commit: String?
    }

    let http: ChiefCloudHTTP
    /// The platform's API (`/v1/artifacts`), the same account's token.
    let platform: URL?
    /// The platform reads' session (tests pass a stub).
    var platformSession: URLSession = AccountCloud.noStoreSession

    /// `/v1/read {op, params}`: the reply's `value` as JSON bytes.
    public func read(_ op: String, params: [String: any Sendable] = [:]) async throws -> Data {
        try await call("/v1/read", ["op": op, "params": params])
    }

    /// `/v1/ops {op, params, idempotency_key, origin: user}`: a write the person made; a retry
    /// with the same key applies once.
    public func mutate(_ op: String, params: [String: any Sendable], key: String) async throws -> Data {
        try await call("/v1/ops", ["op": op, "params": params, "idempotency_key": key, "origin": "user"])
    }

    private func call(_ path: String, _ object: [String: any Sendable]) async throws -> Data {
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: object) } catch { throw Failure.badReply }
        let reply: ChiefCloudHTTP.Reply
        do { reply = try await http.send("POST", path, body: body) } catch {
            throw Self.cancellation(error) ?? Failure.unreachable
        }
        let value: Any?
        do { value = try ChiefCloudHTTP.value(reply) } catch let ChiefCloudError.refused(status, code, message) {
            throw Failure.refused(status: status, code: code, message: message)
        } catch {
            throw Failure.badReply
        }
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else {
            return Data("{}".utf8)
        }
        return data
    }

    /// One authenticated GET of the platform's `path` (`/v1/artifacts/tree`) with `query`, each
    /// value encoded whole so a path never adds a parameter.
    public func platformGet(_ path: String, query: [URLQueryItem]) async throws -> PlatformReply {
        guard let platform, let url = Self.url(base: platform, path: path, query: query) else { throw Failure.unreachable }
        // As the Cloud calls do: one retry with a fresh token after a 401.
        for forceRefresh in [false, true] {
            let token: String
            do { token = try await http.accessToken(forceRefresh) } catch {
                throw Self.cancellation(error) ?? Failure.refused(status: 401, code: "auth.unauthenticated", message: "")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            let reply: PlatformReply
            do {
                let (data, response) = try await platformSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw Failure.badReply }
                reply = PlatformReply(status: http.statusCode, body: data, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                      commit: http.value(forHTTPHeaderField: "X-Artifacts-Commit"))
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Self.cancellation(error) ?? Failure.unreachable
            }
            if reply.status == 401, !forceRefresh { continue }
            return reply
        }
        throw Failure.unreachable
    }

    /// A cancelled call as `CancellationError` (URLSession reports `URLError.cancelled`), so a page
    /// that left or reloaded never shows it as a failure.
    static func cancellation(_ error: any Error) -> CancellationError? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return CancellationError() }
        return nil
    }

    static func url(base: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+;#")
        components.percentEncodedQueryItems = query.isEmpty ? nil : query.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url
    }

    /// Artifact replies carry account data: no shared cache or cookies, and no redirect that could
    /// carry the token to another origin.
    static let noStoreSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    /// The platform API for the Cloud service at `cloud`: production for the production service,
    /// else the development deployment (the Mac's `artifactsAPIBaseURL`). A DEBUG build may name
    /// another platform deployment (`CMUX_MOBILE_ARTIFACTS_API_URL`, `*.debussy.workers.dev` only:
    /// the token goes there).
    public static func platformBase(cloud: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if DEBUG
        if let raw = environment["CMUX_MOBILE_ARTIFACTS_API_URL"], let url = URL(string: raw), isPlatformOrigin(url) { return url }
        #endif
        // The Mac's mapping (CloudConfiguration `artifactsAPIBaseURL`): each Cloud service's own platform.
        switch cloud.host() {
        case "cloud-api.cmux.dev": return URL(string: "https://cmux-platform.debussy.workers.dev")
        case "cloud-api-staging.cmux.dev": return URL(string: "https://cmux-platform-staging.debussy.workers.dev")
        default: return URL(string: "https://cmux-platform-development.debussy.workers.dev")
        }
    }

    static func isPlatformOrigin(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil else { return false }
        return host.hasSuffix(".debussy.workers.dev")
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension ChiefSources {
    /// This account's own Cloud calls, while signed in to a build with a Cloud service.
    public var account: AccountCloud? {
        guard let http else { return nil }
        return AccountCloud(http: http, platform: AccountCloud.platformBase(cloud: http.base))
    }
}
