struct SudoSpawnedProcess: Sendable, Equatable {
    let identity: SudoProcessIdentity
    let processGroupIdentifier: Int32
}
