struct SudoLaunchedRunner: Sendable {
    /// The generation-qualified identity of the spawned hidden runner.
    let identity: SudoProcessIdentity

    /// A single-element stream completed by the app's dedicated child reaper.
    let termination: AsyncStream<Int32>
}
