import Foundation

/// The reachability status of a machine reported by the mobile sync API.
public enum MobileMachineStatus: String, Codable, Equatable, Sendable {
    /// The machine is currently online.
    case online

    /// The machine is currently offline.
    case offline

    /// The machine's status is unknown.
    case unknown
}
