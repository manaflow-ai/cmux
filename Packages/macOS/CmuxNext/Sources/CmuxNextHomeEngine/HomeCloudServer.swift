public import Foundation

/// The chat server the Cloud source reaches through the daemon
/// (`home.server` in cmux.json, dm-group-chat-DESIGN.md section 4.5).
public nonisolated enum HomeCloudServer: Hashable, Sendable {
    /// The build's cmux Cloud, signed in with the Stack account.
    case hosted
    /// A self-hosted server at this origin (`http://mini.tail1234.ts.net:7320`):
    /// the daemon sends it no token, and the server knows the person by their
    /// Tailscale login.
    case selfHosted(URL)
}
