public extension AuthCoordinator {
    /// Monotonic process-local evidence that a local sign-out began.
    ///
    /// Lifecycle consumers use this revision instead of relying on observing
    /// the transient signed-out UI state, which can be coalesced when another
    /// account signs in immediately afterward.
    var signOutRevision: UInt64 { signOutEpoch }
}
