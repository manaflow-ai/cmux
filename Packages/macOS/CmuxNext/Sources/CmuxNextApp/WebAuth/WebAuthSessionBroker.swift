import Foundation

/// The callback that ends a sign-in session: a custom scheme, or an https
/// host and path. The same rule as the system's matcher: scheme and host
/// compare without case, the path ignores one trailing slash, query and
/// fragment do not count (the shim's `auth_callback_policy.h` is the C++ copy).
nonisolated enum WebAuthCallback: Equatable, Sendable {
    case customScheme(String)
    case https(host: String, path: String)
    /// Unknown: nothing matches by this rule (the request's own matcher may).
    case none

    func matches(_ url: URL) -> Bool {
        switch self {
        case .customScheme(let scheme):
            return url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
        case .https(let host, let path):
            guard url.scheme?.lowercased() == "https", let urlHost = url.host(percentEncoded: false) else { return false }
            if let port = url.port, port != 443 { return false }
            guard Self.trimmedHost(urlHost) == Self.trimmedHost(host) else { return false }
            return Self.trimmedPath(url.path(percentEncoded: true)) == Self.trimmedPath(path)
        case .none:
            return false
        }
    }

    private static func trimmedHost(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func trimmedPath(_ path: String) -> String {
        var path = path.isEmpty ? "/" : path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// One sign-in request (`ASWebAuthenticationSessionRequest` in the app,
/// fakes in tests).
@MainActor
protocol WebAuthSessionRequest: AnyObject {
    var id: UUID { get }
    var url: URL { get }
    /// The session must not share cookies or storage with the browser.
    var isEphemeral: Bool { get }
    var callback: WebAuthCallback { get }
    /// The system's own matcher where it has one, else `callback`.
    func matches(_ url: URL) -> Bool
    func complete(with url: URL)
    /// The person ended the sign-in (ASWebAuthenticationSessionError.canceledLogin).
    func cancel()
}

/// The tab a sign-in runs in.
@MainActor
protocol WebAuthSessionSurface: AnyObject {
    func close()
}

/// Opens a sign-in's tab: ephemeral sessions in a non-persistent profile.
/// The tab reports its navigations and its close to `broker`. Nil when no
/// tab can open.
@MainActor
protocol WebAuthSessionOpening: AnyObject {
    func open(_ request: any WebAuthSessionRequest, broker: WebAuthSessionBroker) -> (any WebAuthSessionSurface)?
}

/// Serves other apps' sign-ins while cmux is the default browser: each
/// request opens in a tab and ends exactly once, with its callback URL (the
/// tab closes) or cancelled (the person closed the tab). One owner for the
/// pending sessions; the shim and the tab only report events here.
@MainActor
final class WebAuthSessionBroker {
    struct Session {
        let request: any WebAuthSessionRequest
        var surface: (any WebAuthSessionSurface)?
    }

    private let opener: any WebAuthSessionOpening
    private(set) var pending: [UUID: Session] = [:]
    /// Requests the system cancelled before their begin arrived (the two
    /// reach the main actor in separate tasks, in either order).
    private var cancelledEarly: Set<UUID> = []

    init(opener: any WebAuthSessionOpening) {
        self.opener = opener
    }

    /// The system asks cmux to run `request`. Only a web start page opens.
    func begin(_ request: any WebAuthSessionRequest) {
        if cancelledEarly.remove(request.id) != nil { return }
        guard pending[request.id] == nil else { return }
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return request.cancel() }
        pending[request.id] = Session(request: request, surface: nil)
        guard let surface = opener.open(request, broker: self) else {
            pending[request.id] = nil
            return request.cancel()
        }
        // The tab may have closed (or matched) while it opened.
        if pending[request.id] != nil { pending[request.id]?.surface = surface }
    }

    /// The session's tab went to `url` (main frame). True when that is the
    /// callback: the session completes with it, its tab closes, and the
    /// caller must not load it.
    @discardableResult
    func navigated(_ id: UUID, to url: URL) -> Bool {
        guard let session = pending[id], session.request.matches(url) else { return false }
        pending[id] = nil
        session.request.complete(with: url)
        session.surface?.close()
        return true
    }

    /// The person closed the session's tab before its callback.
    func surfaceClosed(_ id: UUID) {
        guard let session = pending.removeValue(forKey: id) else { return }
        session.request.cancel()
    }

    /// The system ended the session (the requesting app cancelled it): its
    /// tab closes, and nothing answers the request.
    func systemCancelled(_ id: UUID) {
        guard let session = pending.removeValue(forKey: id) else {
            cancelledEarly.insert(id)
            return
        }
        session.surface?.close()
    }
}
