import Foundation

struct SudoSpawnedProcess: Sendable {
    let identity: SudoProcessIdentity
    let processGroupIdentifier: Int32
    let outputURL: URL
    let approvedScriptURL: URL?
    let standardInput: Data?
    let standardInputReadyMarker: Data?
    let controlMarkers: SudoExecutionControlMarkers
    let io: SudoSpawnedProcessIO

}
