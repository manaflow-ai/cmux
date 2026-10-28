package import AuthenticationServices
package import Foundation

/// The system's session handler (`ASWebAuthenticationSessionWebBrowserSessionManager`).
/// macOS calls it on its own queue (the SDK protocol is not main-actor), so
/// the type is `nonisolated`: under the package's main-actor default
/// isolation its `@objc` witnesses would check for the main actor and trap
/// before the hop. It is `Sendable` because its only stored state is
/// immutable and `Sendable`; the compiler checks that for a final `NSObject`
/// subclass, so a later mutable or non-`Sendable` property does not compile.
///
/// Every call goes to the broker on the main actor through one ordered
/// stream, in the order macOS made the calls: a request's cancel never
/// reaches the broker before its begin, so the broker keeps no state for a
/// request it has not seen or that has ended.
package nonisolated final class WebAuthSessionHandler: NSObject, Sendable, ASWebAuthenticationSessionWebBrowserSessionHandling {
    /// One call from macOS, run on the main actor.
    private typealias MainCall = @MainActor @Sendable () -> Void

    private let broker: WebAuthSessionBroker
    /// Where each call from macOS waits for the main actor, first in, first out.
    private let calls: AsyncStream<MainCall>.Continuation

    @MainActor
    package init(broker: WebAuthSessionBroker) {
        // concurrency-allow: one call per sign-in the person starts or ends (human rate), drained at once on the main actor; a dropped begin or cancel would leave the system's request unanswered
        let (stream, calls) = AsyncStream.makeStream(of: MainCall.self, bufferingPolicy: .unbounded)
        self.broker = broker
        self.calls = calls
        super.init()
        // The one consumer runs the calls in order. It holds the stream, not
        // the handler, and ends when the handler goes (deinit finishes the stream).
        Task { @MainActor in
            for await call in stream { call() }
        }
    }

    deinit {
        calls.finish()
    }

    /// The Info.plist key that tells macOS cmux serves sign-ins.
    static let capabilitiesKey = "ASWebAuthenticationSessionWebBrowserSupportCapabilities"

    /// Installs `handler` as the app's session handler (once, at launch:
    /// macOS delivers a request that launched cmux after this). Only a build
    /// whose Info.plist declares the capability installs it (cx-q3y7: the key
    /// waits until macOS delivers requests to a default browser).
    @MainActor
    @discardableResult
    package static func install(_ handler: WebAuthSessionHandler, bundle: Bundle = .main,
                                set: (WebAuthSessionHandler) -> Void = { ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = $0 }) -> Bool {
        guard bundle.object(forInfoDictionaryKey: capabilitiesKey) != nil else { return false }
        set(handler)
        return true
    }

    // The SDK protocol declares an implicitly unwrapped request; Optional is the same type.
    package func begin(_ request: ASWebAuthenticationSessionRequest?) {
        guard let request else { return }
        // crash-allow: the system's session manager owns the request and may read it on its own queue (its cancel reads `uuid` there); every property cmux reads (uuid, URL, ephemeral flag, callback) is immutable, and only the main actor calls complete or cancel on it, once (WebAuthSessionBroker)
        nonisolated(unsafe) let unsafeRequest = request
        let broker = broker
        calls.yield { broker.begin(SystemWebAuthRequest(unsafeRequest)) }
    }

    // The SDK protocol declares an implicitly unwrapped request; Optional is the same type.
    package func cancel(_ request: ASWebAuthenticationSessionRequest?) {
        guard let request else { return }
        // `uuid` is immutable: reading it on the system's queue races nothing.
        let id = request.uuid
        let broker = broker
        calls.yield { broker.systemCancelled(id) }
    }
}
