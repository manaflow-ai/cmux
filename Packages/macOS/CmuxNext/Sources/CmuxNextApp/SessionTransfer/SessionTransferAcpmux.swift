import Foundation

/// This build's acpmux as session transfer needs it: where it listens, its home, and how to
/// run its CLI. A plain value, so the transfer code needs no agent pane type.
nonisolated struct SessionTransferAcpmux: Sendable, Equatable {
    /// The `acpmux` executable a chat move runs.
    let executable: URL
    /// The daemon's socket, which `acpmux transfer --to` names.
    let socketPath: String
    /// The daemon's home, which the list record hands a taker as `acpmux_home`.
    let home: URL
    /// Variables the daemon and its CLI must agree on (`acpmux info` runs with them).
    let childEnvironment: [String: String]
}
