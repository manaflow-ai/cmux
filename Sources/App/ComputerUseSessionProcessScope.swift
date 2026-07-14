import Foundation

/// The allowed process tree for one live agent session while matching driver state files.
struct ComputerUseSessionProcessScope: Sendable {
    let id: String
    let sessionID: String
    let processIDs: Set<Int>
}
