import Foundation

/// What a sheet button does. One path for the click and the key.
public nonisolated enum AddServerAction: Equatable, Sendable {
    /// Approve the found server.
    case approve
    /// Send the refused approve again.
    case retry
    /// Close the sheet after the server was added.
    case done
    /// Drop the draft and close.
    case cancel
}
