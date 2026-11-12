/// Effects to perform only after the deletion owner has committed an outcome.
public enum CloudMachineDeletionTransition: Equatable, Sendable {
    /// A duplicate outcome, or one that outlived its account; apply nothing.
    case ignored
    /// The machine is gone. Retire its local registrations; lists keep hiding it.
    case retired
    /// The delete failed. Lists show the machine again; report the failure.
    case restored
}
