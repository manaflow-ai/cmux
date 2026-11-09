import CmuxNextCompat
public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The Artifacts page (webviews/src/pages/artifacts): the account's synced artifacts and
    /// memories as a tree, a preview and their history, read only. Its three ops are relayed to
    /// cmux-platform's `/v1/artifacts` reads with the app's own bearer; the page never sees a token.
    /// Saved HTML previews in passive srcdoc frames, which never navigate. Signed out, its one action
    /// is the app's Sign In (the page's Sign In button).
    static let artifacts = PageDescriptor(id: "cmux.artifacts", resource: "artifacts", namespaces: ["cmux.artifacts.", "cmux.cloud."],
                                          nativeOps: [PageNativeOp.actionRun], actions: ["palette.auth.signIn"], passiveFrames: true)
}

/// One authenticated GET the provider asks the app to make: `path` under the platform's base URL
/// (`/v1/artifacts/tree`) and its query, already checked.
public nonisolated struct ArtifactsRead: Sendable, Equatable {
    public let path: String
    public let query: [URLQueryItem]

    public init(path: String, query: [URLQueryItem]) {
        self.path = path
        self.query = query
    }
}

/// The platform's answer to an ``ArtifactsRead``.
public nonisolated struct ArtifactsReply: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String?
    /// `X-Artifacts-Commit`: the commit a file read resolved to.
    public let commit: String?

    public init(status: Int, body: Data, contentType: String? = nil, commit: String? = nil) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.commit = commit
    }
}

/// `cmux.artifacts.tree {ref?, path?}`, `cmux.artifacts.history {ref?, path?, limit?}` and
/// `cmux.artifacts.file {path, ref?}`: one platform read each. Every param is checked before
/// anything is sent, so a page can only name a ref, a path and a count. On for everyone: Leo asked for
/// the feature, so it has no Labs gate; signed out, every read answers sign in.
@MainActor
public final class ArtifactsPageProvider: PageProvider {
    /// The host's account-change stream. The page uses it to invalidate private content before
    /// the next tree read, including when sign-out happens while the page stays open.
    public typealias AuthChanges = @MainActor (@escaping @MainActor (JSONValue) -> Void) -> PageSubscription

    /// The history page size the platform takes.
    public static let limitRange: ClosedRange<Int> = 1...100
    /// A file larger than this comes back without its content; the page says it is too large to preview.
    public static let previewLimit = 4 * 1024 * 1024

    private let fetch: @Sendable (ArtifactsRead) async throws -> ArtifactsReply
    private let authChanges: AuthChanges?

    /// - Parameter fetch: Makes the authenticated GET and returns the platform's answer; throws
    ///   when the platform cannot be reached or the person is signed out.
    public init(fetch: @escaping @Sendable (ArtifactsRead) async throws -> ArtifactsReply,
                authChanges: AuthChanges? = nil) {
        self.fetch = fetch
        self.authChanges = authChanges
    }

    /// The Artifacts tab's page: this provider on the app-selected platform API, each read made
    /// with `token`'s access token (nil when signed out). The host supplies the base so release
    /// builds use their production Cloud configuration and debug builds can use a preview.
    public static func page(baseURL: URL?, authChanges: AuthChanges? = nil,
                            token: @escaping @Sendable () async throws -> String?) -> PageWebView? {
        let provider = ArtifactsPageProvider(fetch: platformFetch(base: baseURL, token: token), authChanges: authChanges)
        return PageWebView(descriptor: .artifacts, routes: [PageRoute(prefix: "cmux.artifacts.", provider: provider),
                                                            PageRoute(prefix: "cmux.cloud.", provider: provider)])
    }

    /// Bridges the app's observed account identity to the page's invalidation stream.
    public static func authChanges(accountID: @escaping @MainActor @Sendable () -> String?) -> AuthChanges {
        { onEvent in
            let task = Task { @MainActor in
                var previous = accountID()
                for await next in ObservationStream(accountID) {
                    guard next != previous else { continue }
                    previous = next
                    onEvent(.object([:]))
                }
            }
            return PageSubscription { task.cancel() }
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.cloud.auth.watch", let authChanges else { throw PageError.unknownOp(stream) }
        return authChanges(onEvent)
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let read = try Self.read(op, params)
        let reply: ArtifactsReply
        do {
            reply = try await fetch(read)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PageError(code: "cmux.artifacts.unavailable", message: Self.unreachable, retryable: true)
        }
        switch reply.status {
        case 200..<300: break
        case 401, 403: throw PageError(code: "cmux.artifacts.signed_out", message: Self.signedOut, retryable: true)
        case 404: throw PageError(code: "cmux.artifacts.not_found", message: Self.notFound)
        default: throw PageError(code: "cmux.artifacts.failed", message: Self.failed, retryable: true)
        }
        guard op == "cmux.artifacts.file" else {
            guard let value = try? JSONValue.parse(reply.body) else {
                throw PageError(code: "cmux.artifacts.failed", message: Self.failed, retryable: true)
            }
            return value
        }
        var file: [String: JSONValue] = [
            "path": .string(params["path"]?.stringValue ?? ""),
            "size": .number(Double(reply.body.count)),
            "contentType": .string(reply.contentType ?? "application/octet-stream"),
            "commit": .string(reply.commit ?? ""),
        ]
        if reply.body.count > Self.previewLimit {
            file["tooLarge"] = .bool(true)
        } else if let text = String(data: reply.body, encoding: .utf8) {
            file["content"] = .string(text)
        } else {
            file["content"] = .string(reply.body.base64EncodedString())
            file["encoding"] = .string("base64")
        }
        return .object(file)
    }

    /// cmux-platform's development Worker, which serves `/v1/artifacts` first.
    public static let developmentAPI = URL(string: "https://cmux-platform-development.debussy.workers.dev")

    /// The API base: `CMUX_NEXT_ARTIFACTS_API_URL` when it names a platform deployment
    /// (``isPlatformOrigin(_:)``), else ``developmentAPI``. The bearer goes to this host, so an
    /// override elsewhere is ignored.
    public static func apiBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let value = environment["CMUX_NEXT_ARTIFACTS_API_URL"], let url = URL(string: value), isPlatformOrigin(url) { return url }
        return developmentAPI
    }

    /// A cmux-platform Worker over https (`*.debussy.workers.dev`), or `wrangler dev` on this Mac
    /// (http on loopback). No user, password, query or fragment.
    public static func isPlatformOrigin(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return false }
        switch url.scheme?.lowercased() {
        case "https": return host.hasSuffix(".debussy.workers.dev") && url.port == nil
        case "http": return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default: return false
        }
    }

    /// The app's fetch: one GET of `read` under `base` with the bearer `token` gives, or a 401
    /// answer when `token` gives nil (signed out).
    public nonisolated static func platformFetch(base: URL?, token: @escaping @Sendable () async throws -> String?)
        -> @Sendable (ArtifactsRead) async throws -> ArtifactsReply {
        let session = noStoreSession()
        return { read in
            guard let base else { throw URLError(.badURL) }
            guard let access = try await token() else { return ArtifactsReply(status: 401, body: Data()) }
            guard let url = url(read, base: base) else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return ArtifactsReply(status: http.statusCode, body: body, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                  commit: http.value(forHTTPHeaderField: "X-Artifacts-Commit"))
        }
    }

    /// Artifact replies carry account data. Keep them out of shared URLSession caches and cookies,
    /// and never follow a redirect that could move the bearer to another origin.
    private nonisolated static func noStoreSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    /// `read`'s URL under `base`, whose own path (a deployment under a prefix) is kept. Each query
    /// value is encoded whole (`&`, `=`, `+`, `;` and `#` included), so a path can never add a param.
    nonisolated static func url(_ read: ArtifactsRead, base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + read.path
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+;#")
        components.percentEncodedQueryItems = read.query.isEmpty ? nil : read.query.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url
    }

    /// The platform read for `op` and `params`, or ``PageError/invalidParams(_:)`` for a param
    /// that is not a short string (ref, path) or an integer in ``limitRange`` (limit).
    static func read(_ op: String, _ params: JSONValue) throws -> ArtifactsRead {
        func text(_ key: String, max: Int) throws -> String? {
            guard let value = params[key], !value.isNull else { return nil }
            guard let text = value.stringValue, text.utf8.count <= max, !text.contains(where: \.isNewline) else {
                throw PageError.invalidParams("\(key) must be a string of at most \(max) bytes")
            }
            return text
        }
        let ref = try text("ref", max: 256)
        let path = try text("path", max: 4096)
        var query: [URLQueryItem] = []
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        switch op {
        case "cmux.artifacts.tree":
            if let path, !path.isEmpty { query.append(URLQueryItem(name: "path", value: path)) }
            return ArtifactsRead(path: "/v1/artifacts/tree", query: query)
        case "cmux.artifacts.history":
            if let path, !path.isEmpty { query.append(URLQueryItem(name: "path", value: path)) }
            if let value = params["limit"], !value.isNull {
                guard let limit = value.intValue, limitRange.contains(limit) else {
                    throw PageError.invalidParams("limit must be an integer from \(limitRange.lowerBound) to \(limitRange.upperBound)")
                }
                query.append(URLQueryItem(name: "limit", value: String(limit)))
            }
            return ArtifactsRead(path: "/v1/artifacts/history", query: query)
        case "cmux.artifacts.file":
            guard let path, !path.isEmpty else { throw PageError.invalidParams("path is required") }
            query.append(URLQueryItem(name: "path", value: path))
            return ArtifactsRead(path: "/v1/artifacts/file", query: query)
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// The tab's title.
    public static var title: String { t("artifacts.tab.title", "Artifacts") }

    static var unreachable: String {
        t("artifacts.unreachable", "Artifacts could not be reached. Check that you are signed in and online, then try again.")
    }

    static var signedOut: String {
        t("artifacts.signedOut", "Sign in to cmux to see your artifacts.")
    }

    static var notFound: String {
        t("artifacts.notFound", "Nothing has been saved here yet.")
    }

    static var failed: String {
        t("artifacts.failed", "Artifacts could not be loaded. Try again.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
