public import Foundation
import OSLog

nonisolated private let pushRedirectLog = Logger(
    subsystem: "ai.manaflow.cmux",
    category: "push.redirect"
)

/// Preserves mutating push requests across safe redirects and rejects unsafe hops.
///
/// Foundation normally rewrites `POST` and `DELETE` to a body-less `GET` for
/// 301/302 responses. That turns a successful redirect target into a false
/// registration/send acknowledgement. This delegate restores the original
/// method, body, and headers for same-origin 301/302 responses. Same-origin
/// 307/308 requests already preserve the method, but their credential headers
/// are re-applied defensively.
///
/// Every cross-origin redirect is refused before credentials or notification
/// data reach the target. A 303 from a mutating request is refused because its
/// body-less GET cannot acknowledge that the original mutation completed.
public final class RedirectMethodPreservingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    // URLSession's redirect delegate callback and the public refusal read are
    // both synchronous on different executors, so an actor cannot own this
    // single-bit handoff without changing either API to async.
    private let refusalLock = NSLock()
    private var refusedRedirectValue = false

    /// Creates a stateless per-owner redirect delegate.
    public override init() {
        super.init()
    }

    /// Whether this request was stopped by the redirect policy.
    public var refusedRedirect: Bool {
        refusalLock.withLock { refusedRedirectValue }
    }

    /// Applies the redirect policy to one URL loading task.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest proposedRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest,
              Self.sameOrigin(original.url, proposedRequest.url) else {
            markRefused()
            pushRedirectLog.error(
                "Refused cross-origin push redirect status=\(response.statusCode, privacy: .public)"
            )
            completionHandler(nil)
            return
        }

        let originalMethod = original.httpMethod?.uppercased() ?? "GET"
        let isMutation = Self.mutatingMethods.contains(originalMethod)
        if response.statusCode == 303, isMutation {
            markRefused()
            pushRedirectLog.error("Refused mutating push 303 redirect")
            completionHandler(nil)
            return
        }

        guard isMutation, (301...302).contains(response.statusCode)
                || (307...308).contains(response.statusCode) else {
            completionHandler(proposedRequest)
            return
        }
        guard original.httpBodyStream == nil else {
            markRefused()
            pushRedirectLog.error("Refused non-replayable push redirect body")
            completionHandler(nil)
            return
        }

        var preserved = proposedRequest
        preserved.httpMethod = originalMethod
        preserved.httpBody = original.httpBody
        for (field, value) in original.allHTTPHeaderFields ?? [:] {
            preserved.setValue(value, forHTTPHeaderField: field)
        }
        pushRedirectLog.info(
            "Preserved push \(originalMethod, privacy: .public) across status=\(response.statusCode, privacy: .public)"
        )
        completionHandler(preserved)
    }

    private func markRefused() {
        refusalLock.withLock {
            refusedRedirectValue = true
        }
    }

    private static let mutatingMethods = Set(["POST", "PUT", "PATCH", "DELETE"])
    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              ["http", "https"].contains(lhsScheme),
              ["http", "https"].contains(rhsScheme),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              !lhsHost.isEmpty,
              !rhsHost.isEmpty
        else { return false }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https", "wss":
            return 443
        case "http", "ws":
            return 80
        default:
            return nil
        }
    }
}
