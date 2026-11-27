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
    /// The page to load instead of `url`, a stopped navigation that is not the callback but must not load as it is
    /// (the app's own GitHub connect sends GitHub's code-less return on to the authorize page); nil: `url` loads.
    func redirect(_ url: URL) -> URL?
    /// The app's own flow: its panel opens over the app's front window. Another app's sign-in opens centered on screen.
    var opensOverAppWindow: Bool { get }
}

extension WebAuthSessionRequest {
    package func redirect(_ url: URL) -> URL? { nil }
    package var opensOverAppWindow: Bool { false }
}
