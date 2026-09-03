import Foundation

struct CloudPrivateNetworkUse: Sendable, Equatable {
    enum Purpose: String, Sendable {
        case ssh
        case attach
        case cmuxRemote = "cmux-remote"
        case sessionAttach = "session-attach"
        case openPort = "open-port"
    }

    let machineID: String
    let purpose: Purpose
}

/// The gate for builds and tests that do not manage a tunnel: dial straight
/// away, exactly as before the app-managed tunnel existed.
