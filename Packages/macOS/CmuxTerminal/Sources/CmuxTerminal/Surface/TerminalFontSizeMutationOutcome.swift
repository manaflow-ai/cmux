/// Result of one terminal font-size mutation.
///
/// `alreadySatisfied` is successful provenance even though it did not mutate
/// the surface. `failed` must remain eligible for a later reconciliation pass.
public enum TerminalFontSizeMutationOutcome: Sendable, Equatable {
    /// The mutation changed the terminal's font-size state.
    case applied
    /// The terminal already represented the requested font-size state.
    case alreadySatisfied
    /// The native terminal rejected the mutation.
    case failed

    /// Whether the mutation changed the terminal's font-size state.
    public var didChange: Bool {
        self == .applied
    }

    /// Whether the mutation reached the requested state.
    public var didSucceed: Bool {
        self != .failed
    }
}
