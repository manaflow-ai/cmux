/// Receives release-visible slow CLI socket command observations.
nonisolated public protocol SlowSocketCommandSink: AnyObject, Sendable {
    func recordSlowCommand(_ observation: SocketCommandObservation)
}
