public import Foundation
import OSLog

private let redirectLog = Logger(subsystem: "ai.manaflow.cmux", category: "push")

/// A `URLSessionTaskDelegate` that keeps a mutating request's HTTP method and
/// body across a **same-origin** HTTP redirect.
///
/// Foundation's default redirect handling downgrades a `POST`/`DELETE` to a
/// body-less `GET` on a 301/302/303 (only 307/308 preserve the method). For a
/// canonicalizing redirect that turned `POST /api/device-tokens` into a `GET`
/// with no body, the iOS device token silently never registered and push went
/// dead end-to-end (https://github.com/manaflow-ai/cmux/issues/6270). The same
/// hazard hit the Mac's `POST /api/notifications/push` forward. Pointing the
/// production API base at `cmux.com` removed the specific cross-host trigger,
/// but any future *same-origin* redirect (a trailing-slash normalization, an
/// `http`->`https` upgrade on the same host) would silently reintroduce it.
/// Routing the push register/forward requests through this delegate makes them
/// robust to that class.
///
/// Fails closed across origins. The restored payload — a notification body in
/// the `PhonePushClient` path — is potentially sensitive, and Foundation has
/// already stripped `Authorization` for a cross-origin hop, so re-sending the
/// method+body to a *different* origin would leak content to wherever the
/// redirect points. Only a same-origin redirect (scheme + host + port match) is
/// restored; a cross-origin redirect keeps Foundation's proposed (body-less,
/// unauthenticated) request, so it fails loudly with a non-2xx instead of
/// leaking the payload or silently "succeeding" as the wrong method.
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

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Only intervene when Foundation actually changed the method (the
        // 301/302/303 downgrade); 307/308 already preserve it, so follow as-is.
        guard let original = task.originalRequest,
              let originalMethod = original.httpMethod,
              request.httpMethod != originalMethod else {
            completionHandler(request)
            return
        }
        // Fail closed across origins: never re-send a stripped-auth payload to a
        // different origin. Restore only on a same-origin redirect.
        guard sameOrigin(original.url, request.url) else {
            redirectLog.info(
                "Not restoring \(originalMethod, privacy: .public) across a cross-origin HTTP \(response.statusCode, privacy: .public) redirect; following Foundation's proposed request (fails closed)"
            )
            completionHandler(request)
            return
        }
        var preserved = request
        preserved.httpMethod = originalMethod
        // Restores a body set via `httpBody` (every push request builds its body
        // with `JSONSerialization`). A body set via `httpBodyStream` cannot be
        // replayed — the stream was already consumed sending the first request —
        // so it is left as Foundation proposed and logged. No current caller
        // uses a streamed body; this guard keeps a future one from silently
        // sending an empty body.
        if let body = original.httpBody {
            preserved.httpBody = body
        } else if original.httpBodyStream != nil {
            redirectLog.error(
                "Cannot restore a streamed (httpBodyStream) request body across a redirect; the target may receive an empty body"
            )
        }
        redirectLog.info(
            "Preserving \(originalMethod, privacy: .public) across same-origin HTTP \(response.statusCode, privacy: .public) redirect (Foundation proposed \(request.httpMethod ?? "GET", privacy: .public))"
        )
        completionHandler(preserved)
    }

    /// Same scheme + host + port (case-insensitive scheme/host). A `nil` URL on
    /// either side is treated as not-same-origin so it fails closed.
    private func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}
