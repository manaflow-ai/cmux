/// What the detector does with a main-thread blocking call.
public enum BlockingMode: String, Sendable {
    /// Stop the process at the call (Debug with `CMUX_BLOCKING_TRAP=1`, and the detector's tests).
    case trap
    /// Record it once per call site and continue (bench and Nightly builds always; Debug by default
    /// until the known violations are fixed, lead decision 2026-10-24). A contended ``Mutex`` wait is
    /// always recorded, never a trap.
    case record
}
