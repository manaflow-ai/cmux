internal import Foundation

/// Localized wire messages handed to ``CMUXSidebarExtensionHostXPC`` by the app
/// composition root.
///
/// The host coordinator returns these strings to the extension process over the
/// XPC reply channel. They are resolved with `String(localized:)` in the app
/// target so the app bundle's localized catalog (including Japanese) is used;
/// resolving them inside the package would bind to the package bundle, which has
/// no catalog, and silently drop every non-English translation.
@_spi(CmuxHostTransport)
public struct CMUXSidebarExtensionHostXPCStrings: Sendable {
    /// Returned to the extension when it attempts an action whose required
    /// scopes are not granted.
    public let scopeRejected: String
    /// Returned to the extension when a request arrives on a connection that is
    /// no longer the host's current generation.
    public let staleConnection: String

    public init(scopeRejected: String, staleConnection: String) {
        self.scopeRejected = scopeRejected
        self.staleConnection = staleConnection
    }
}
