package import Foundation

/// One sign-in request (`ASWebAuthenticationSessionRequest` from the system,
/// fakes in tests).
@MainActor
package protocol WebAuthSessionRequest: AnyObject {
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
