/// What the detector does with a main-thread blocking call.
public enum BlockingMode: String, Sendable {
    /// Stop the process at the call (Debug by default since the sweep passed in record mode, task
    /// p02-threads-021; Chrome's `DCHECK` in `base::ScopedBlockingCall`).
    case trap
    /// Record it once per call site and continue (bench builds always, and Nightly to come; Debug started
    /// with `CMUX_BLOCKING_TRAP=0`). A contended ``Mutex`` wait is always recorded, never a trap.
    case record
}
