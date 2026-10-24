package import AuthenticationServices
package import Foundation

/// The system's session handler (`ASWebAuthenticationSessionWebBrowserSessionManager`).
/// macOS calls it on its own queue (the SDK protocol is not main-actor), so
/// the type is `nonisolated`: under the package's main-actor default
/// isolation its `@objc` witnesses would check for the main actor and trap
/// before the hop. Every request goes to the broker on the main actor.
package nonisolated final class WebAuthSessionHandler: NSObject, ASWebAuthenticationSessionWebBrowserSessionHandling {
    private let broker: WebAuthSessionBroker

    @MainActor
    package init(broker: WebAuthSessionBroker) {
        self.broker = broker
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
        // crash-allow: the request object is only read on the main actor after this hop; nothing else holds it
        nonisolated(unsafe) let unsafeRequest = request
        let broker = broker
        Task { @MainActor in broker.begin(SystemWebAuthRequest(unsafeRequest)) }
    }

    // The SDK protocol declares an implicitly unwrapped request; Optional is the same type.
    package func cancel(_ request: ASWebAuthenticationSessionRequest?) {
        guard let request else { return }
        let id = request.uuid
        let broker = broker
        Task { @MainActor in broker.systemCancelled(id) }
    }
}
