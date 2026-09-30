public import Foundation

/// The connection lifecycle of one SSH machine, as a pure reducer.
public struct SSHConnectionMachine: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case offline
        case connecting
        case connected
        case authFailed(String)
        case hostKeyUntrusted(String)
        case unreachable(String)
        case needsInstall(InstallNeed)
        case installing
        case installFailed(String)
        case failed(String)
    }

    public enum Wake: Hashable, Sendable {
        case user
        case appActivated
        case systemWake
        case networkChanged
    }

    public enum InstallOutcome: Hashable, Sendable {
        case success
        case failure(String)
    }

    public enum Event: Hashable, Sendable {
        case connect
        case disconnect
        case attemptStarted
        case probed(InstallNeed)
        case failed(SSHFailure)
        case linkUp
        case linkLost
        case wake(Wake)
        case installStarted
        case installFinished(InstallOutcome)
    }

    public private(set) var status: Status = .offline

    public init() {}

    public var mayAttempt: Bool { false }

    public mutating func handle(_ event: Event) {}
}
