public import Foundation
import OSLog

private let redirectLog = Logger(subsystem: "ai.manaflow.cmux", category: "push")

/// A `URLSessionTaskDelegate` that keeps a mutating request's HTTP method and
/// body across a **same-origin 301/302** HTTP redirect.
///
/// Foundation's default redirect handling downgrades a `POST`/`DELETE` to a
/// body-less `GET` on a 301/302 (and 303). For a canonicalizing 301/302 that
/// turned `POST /api/device-tokens` into a `GET` with no body, the iOS device
/// token silently never registered and push went dead end-to-end
/// (https://github.com/manaflow-ai/cmux/issues/6270). The same hazard hit the
/// Mac's `POST /api/notifications/push` forward. Pointing the production API base
/// at `cmux.com` removed the specific cross-host trigger, but any future
/// *same-origin* 301/302 (a trailing-slash normalization, an `http`->`https`
/// upgrade on the same host) would silently reintroduce it. Routing the push
/// register/forward requests through this delegate makes them robust to that
/// class.
///
/// Scope is deliberately narrow:
/// - **Cross-origin redirects are refused** (`completionHandler(nil)`),
///   regardless of status — including method-preserving 307/308. These requests
///   carry sensitive custom headers (`X-Stack-Refresh-Token`, `X-Cmux-Team-Id`)
///   that Foundation does NOT strip on a cross-origin hop (it only strips
///   `Authorization`), and the `PhonePushClient` body is a notification payload;
///   they only ever target our own API, so any redirect to another origin is
///   refused. Nothing — body or headers — leaves the app toward another origin;
///   the task completes with the 3xx (a visible non-2xx) instead.
/// - Of the **same-origin** redirects, only a method-changing **301/302** is
///   restored. A **303** ("See Other") is by spec a GET follow-up, so replaying
///   the body would be a second mutating call — it is left as Foundation
///   proposed; 307/308 already preserve the method, so nothing is restored.
/// - A body that cannot be replayed (`httpBodyStream`) is also left as proposed
///   (no current caller streams a body).
///
/// Stateless: each owner constructs and retains its own instance (there is no
/// state to share, so a per-owner instance is equivalent to a global one and
/// avoids a package singleton). Used as a per-task delegate via
/// `URLSession.data(for:delegate:)`, which works even on `URLSession.shared`
/// (the shared session only forbids a session-level delegate, not per-task ones).
public final class RedirectMethodPreservingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Creates a stateless redirect delegate. The owning service constructs and
    /// retains one, then passes it to `URLSession.data(for:delegate:)`.
    public override init() { super.init() }

    /// `URLSessionTaskDelegate` hook (dispatched by URLSession, not called from
    /// Swift): refuses every cross-origin redirect (any status), and on a
    /// method-changing **same-origin 301/302** restores the original method +
    /// `httpBody` so a `POST`/`DELETE` is not silently followed as a body-less
    /// `GET`. 303 keeps Foundation's GET; 307/308 already preserve the method.
    /// Public only to satisfy the public protocol requirement.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest else {
            completionHandler(request)
            return
        }
        // Refuse cross-origin redirects FIRST, before any method check, so a
        // method-preserving 307/308 cannot slip through. Following Foundation's
        // proposed request would forward sensitive custom headers
        // (X-Stack-Refresh-Token, X-Cmux-Team-Id) and the body to the new origin —
        // Foundation only strips Authorization — and these requests only ever
        // target our own API. Refusing (nil) sends nothing to the other origin;
        // the task completes with the 3xx (a visible non-2xx).
        guard sameOrigin(original.url, request.url) else {
            redirectLog.info(
                "Refusing a cross-origin HTTP \(response.statusCode, privacy: .public) redirect (fail closed)"
            )
            completionHandler(nil)
            return
        }
        // Same-origin: restore only the accidental method downgrade (301/302). A
        // 303 ("See Other") is by spec a GET follow-up, so replaying the body
        // would be a second mutating call; 307/308 preserve the method already
        // (nothing changed). Either way, follow Foundation's proposed request.
        guard let originalMethod = original.httpMethod,
              request.httpMethod != originalMethod,
              response.statusCode == 301 || response.statusCode == 302 else {
            completionHandler(request)
            return
        }
        // Restore the verb only when the body can come with it. Every push
        // request builds its body with `JSONSerialization` (`httpBody`); a body
        // set via `httpBodyStream` was already consumed sending the first
        // request and cannot be replayed, so restoring just the verb would send
        // a body-less POST/DELETE — worse than failing the redirect. In that
        // case (no current caller streams), fail closed and follow Foundation's
        // proposed request so it fails loudly.
        guard let body = original.httpBody else {
            if original.httpBodyStream != nil {
                redirectLog.error(
                    "Cannot restore a streamed (httpBodyStream) request body across a redirect; following Foundation's proposed request (fails closed)"
                )
            }
            completionHandler(request)
            return
        }
        var preserved = request
        preserved.httpMethod = originalMethod
        preserved.httpBody = body
        redirectLog.info(
            "Preserving \(originalMethod, privacy: .public) across same-origin HTTP \(response.statusCode, privacy: .public) redirect (Foundation proposed \(request.httpMethod ?? "GET", privacy: .public))"
        )
        completionHandler(preserved)
    }

    /// Same scheme + host + port (case-insensitive scheme/host). Default ports
    /// compare equal to an absent port (`https://h` == `https://h:443`). A `nil`
    /// URL on either side is treated as not-same-origin so it fails closed.
    private func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    /// The URL's explicit port, or the scheme's default (443 for https/wss, 80
    /// for http/ws), so an absent port matches the scheme's default port.
    private func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https", "wss": return 443
        case "http", "ws": return 80
        default: return nil
        }
    }
}
