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
    /// The body's length when the host left a long body out (`body` empty); nil: `body.count`.
    public let size: Int?

    public init(status: Int, body: Data, contentType: String? = nil, commit: String? = nil, size: Int? = nil) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.commit = commit
        self.size = size
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

    /// The Artifacts tab's page: this provider with the host's `fetch`, which makes each read
    /// through the daemon's `cloud.artifacts.read` (cmux-cloud-api `artifacts.rs`) on the
    /// app-selected platform origin, so release builds read production Cloud.
    public static func page(fetch: @escaping @Sendable (ArtifactsRead) async throws -> ArtifactsReply,
                            authChanges: AuthChanges? = nil) -> PageWebView? {
        let provider = ArtifactsPageProvider(fetch: fetch, authChanges: authChanges)
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
            "size": .number(Double(reply.size ?? reply.body.count)),
            "contentType": .string(reply.contentType ?? "application/octet-stream"),
            "commit": .string(reply.commit ?? ""),
        ]
        if (reply.size ?? reply.body.count) > Self.previewLimit {
            file["tooLarge"] = .bool(true)
        } else if let text = String(data: reply.body, encoding: .utf8) {
            file["content"] = .string(text)
        } else {
            file["content"] = .string(reply.body.base64EncodedString())
            file["encoding"] = .string("base64")
        }
        return .object(file)
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
        t("artifacts.unreachable", "Artifacts could not be reached. Check that you are signed in and online.")
    }

    static var signedOut: String {
        t("artifacts.signedOut", "Sign in to cmux to see your artifacts.")
    }

    static var notFound: String {
        t("artifacts.notFound", "Nothing has been saved here yet.")
    }

    static var failed: String {
        t("artifacts.failed", "Artifacts could not be loaded.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .localizedModule)
    }
}
