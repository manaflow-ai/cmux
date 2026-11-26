protocol SudoProcessSpawning: Sendable {
    func spawn(_ command: SudoExecutionCommand) throws -> SudoSpawnedProcess
}
