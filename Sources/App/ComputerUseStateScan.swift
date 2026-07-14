import Foundation

/// The validated recent driver states produced by one state-directory scan.
struct ComputerUseStateScan: Equatable, Sendable {
    static let empty = ComputerUseStateScan(newestStateByScopeID: [:], hasRecentStateFiles: false)

    let newestStateByScopeID: [String: ComputerUseDriverState]
    let hasRecentStateFiles: Bool
}
