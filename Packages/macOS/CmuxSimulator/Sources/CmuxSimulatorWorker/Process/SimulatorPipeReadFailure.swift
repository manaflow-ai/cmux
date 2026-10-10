import Darwin

/// A failed `read` or `poll` on a drained subprocess pipe.
///
/// A failure is not end of file: the output that was read before it is
/// incomplete, so a subprocess result built from it must not count as success.
struct SimulatorPipeReadFailure: Equatable, Sendable {
    /// The reader's name, which identifies the stream (standard output or error).
    let streamName: String
    /// The `errno` value from the failed call.
    let code: Int32
}
