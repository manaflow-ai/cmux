import Foundation

/// Serializes the real-subprocess tests in this target against each other.
///
/// `RemoteSessionProcessRunnerTests`, `RemotePlatformProbeScriptTests`, and the
/// `ssh -G` cases of `RemoteHostReachabilityProbeTests` each spawn a real
/// `Process` with `Pipe`s and raw-read the pipe file descriptors.
/// The `.serialized` suite trait orders the tests *within* one suite, but the
/// process-global fd table is shared across suites: a `FileHandle` one suite
/// closes can have its descriptor immediately recycled by another suite's
/// pipe, cross-wiring captured stdout/stderr. The within-suite ordering left
/// that cross-suite window open, and it surfaces once enough parallel test
/// load (e.g. an additional suite) schedules the two process suites
/// concurrently. Both suites take this lock with `lock()` / `defer unlock()`
/// around each real-process critical section, extending the ordering across
/// suites so a descriptor can never be recycled under another suite's
/// concurrent reader.
let remoteSubprocessTestLock = NSLock()
