import Testing

/// Serializes suites that spawn real subprocesses and use process-global file descriptors.
///
/// Swift Testing runs sibling suites concurrently by default. Keeping these
/// suites under one recursive `.serialized` parent prevents pipe descriptors
/// from being recycled across overlapping `Process` tests without blocking
/// cooperative-executor threads on a process-wide lock.
@Suite("Remote subprocess tests", .serialized)
struct RemoteSubprocessTests {}
