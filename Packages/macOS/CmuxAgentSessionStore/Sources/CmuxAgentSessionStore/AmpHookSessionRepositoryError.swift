/// A failure to read or decode cmux's managed Amp session history.
public enum AmpHookSessionRepositoryError: Error, Equatable, Sendable {
    /// The store exists but could not be read as a valid Amp hook-session store.
    case unreadableStore
}
