import Foundation

/// The one message MCP Servers shows above its list after a request.
public nonisolated enum McpServersNotice: Equatable, Sendable {
    /// No acpmux answered as the person: nothing can be read or changed.
    case unavailable
    /// acpmux refused or failed the request.
    case failed
    /// The server did not take the key; nothing was kept.
    case keyRefused
    /// The key was taken and the server is connected.
    case keySaved
    /// The sign-in page opened in a browser tab.
    case signInOpened
    /// The connection was removed.
    case removed
    /// The held tools were approved: agents can see and call them.
    case toolsApproved
}
