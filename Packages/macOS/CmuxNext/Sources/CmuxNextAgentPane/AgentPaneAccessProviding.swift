import Foundation

/// The App side of the missing-access card (``AgentPaneAccessRequest``): the native API key sheet
/// and the Keychain, acpmux's routes, and the cmux credits API with its Checkout page. The App
/// target conforms (it owns the window, the sign-in and the browser); tests pass a fake.
@MainActor
public protocol AgentPaneAccessProviding: AnyObject {
    /// Answers `request`. `acpmuxSocket` is this Mac's acpmux unix socket, which writes routes and
    /// secrets; nil when the pane has none.
    func respond(to request: AgentPaneAccessRequest, acpmuxSocket: String?) async -> AgentPaneAccessReply
}
