/// Whether a terminal runtime is allowed to start while its owner commits restore state.
enum TerminalSurfaceStartupRestoreAdmissionPhase: Sendable {
    /// The terminal was not created behind the startup-restore admission gate.
    case unrestricted

    /// Runtime creation is blocked until the owning topology commits restore state.
    case awaitingAdmission

    /// The owning topology committed restore state and released runtime creation.
    case admitted
}
