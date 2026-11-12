import Foundation

/// Everything one drained subprocess pipe produced.
struct SimulatorPipeReadResult: Sendable {
    /// The bytes read, up to the reader's limit.
    let data: Data
    /// Whether output past the limit was discarded.
    let truncated: Bool
    /// Why reading stopped early, or nil when the pipe reached end of file or
    /// the bounded stop.
    let failure: SimulatorPipeReadFailure?

    init(data: Data, truncated: Bool, failure: SimulatorPipeReadFailure? = nil) {
        self.data = data
        self.truncated = truncated
        self.failure = failure
    }
}
