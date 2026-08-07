struct SudoLaunchedRunner: Sendable {
    /// A single-element stream completed by the app's dedicated child reaper.
    let termination: AsyncStream<Int32>
}
