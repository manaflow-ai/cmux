public import Foundation
import OSLog

private let redirectLog = Logger(subsystem: "ai.manaflow.cmux", category: "push")

/// A `URLSessionTaskDelegate` that keeps a mutating request's HTTP method and
/// body across an HTTP redirect.
///
/// Foundation's default redirect handling downgrades a `POST`/`DELETE` to a
/// body-less `GET` on a 301/302/303 (only 307/308 preserve the method). For a
/// canonicalizing redirect — historically `cmux.dev` -> `cmux.com`, which 301s —
/// that turned `POST /api/device-tokens` into a `GET` with no body, so the
/// device token silently never registered and iOS push went dead end-to-end
/// (https://github.com/manaflow-ai/cmux/issues/6270). Pointing the production
/// API base at `cmux.com` removed that specific trigger, but any future redirect
/// (a CDN/host change, a `LocalConfig.plist` `ApiBaseURL` override, a
/// trailing-slash normalization) would silently reintroduce it. Routing the push
/// register/forward requests through this delegate makes them robust to the whole
/// class instead of depending on no redirect ever appearing.
///
/// Sensitive headers that Foundation strips on a CROSS-origin redirect (e.g.
/// `Authorization`) are deliberately NOT re-attached: a redirect to another host
/// then fails loudly with a 401 (a visible, retryable non-2xx) rather than
/// leaking the bearer token off-origin or silently "succeeding" as the wrong
/// method. A same-origin redirect keeps its headers, so restoring the method and
/// body alone fully repairs it.
///
/// Stateless and safe to share: a single ``shared`` instance can back every
/// request. Used as a per-task delegate via `URLSession.data(for:delegate:)`,
/// which works even on `URLSession.shared` (the shared session only forbids a
/// session-level delegate, not per-task ones).
public final class RedirectMethodPreservingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// A shared, stateless instance (the delegate holds no mutable state).
    public static let shared = RedirectMethodPreservingDelegate()

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
        var preserved = request
        preserved.httpMethod = originalMethod
        preserved.httpBody = original.httpBody
        redirectLog.info(
            "Preserving \(originalMethod, privacy: .public) across HTTP \(response.statusCode, privacy: .public) redirect (Foundation proposed \(request.httpMethod ?? "GET", privacy: .public))"
        )
        completionHandler(preserved)
    }
}
