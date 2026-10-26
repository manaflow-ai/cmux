/// What the detector does with a main-thread blocking call.
public enum BlockingMode: String, Sendable {
    /// Stop the process at the call (Debug by default since the record-mode sweep passed, task p02-threads-021;
    /// Chrome's `DCHECK` in base/threading/scoped_blocking_call.cc).
    case trap
    /// Record it once per call site and continue (bench-checks builds always, and Nightly to come; Debug started
    /// with `CMUX_BLOCKING_TRAP=0`). A contended ``Mutex`` wait is always recorded, never a trap.
    case record
}
