import Foundation

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
