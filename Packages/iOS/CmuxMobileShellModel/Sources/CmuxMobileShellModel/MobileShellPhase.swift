import Foundation

/// The top-level phase the mobile shell is presenting.
public enum MobileShellPhase: Equatable, Sendable {
    /// The user is signing in.
    case signIn
    /// The user is pairing with a Mac.
    case pairing
    /// The user is browsing workspaces on a paired Mac.
    case workspaces
}
