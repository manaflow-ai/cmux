import Foundation

/// What a ``CloudPrivateNetworkUse`` is about to do on the private network,
/// for logging and consumer accounting. Raw values are stable log tokens.
enum CloudPrivateNetworkPurpose: String, Sendable {
    case ssh
    case attach
    case cmuxRemote = "cmux-remote"
    case sessionAttach = "session-attach"
    case openPort = "open-port"
}
