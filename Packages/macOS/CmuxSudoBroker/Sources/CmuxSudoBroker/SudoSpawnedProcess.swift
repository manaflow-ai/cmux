import Foundation

struct SudoSpawnedProcess: Sendable, Equatable {
    let identity: SudoProcessIdentity
    let processGroupIdentifier: Int32
    let outputURL: URL
}
