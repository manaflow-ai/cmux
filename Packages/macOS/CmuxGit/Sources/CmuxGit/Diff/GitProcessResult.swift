internal import Foundation

struct GitProcessResult: Sendable {
    /// Exact stdout bytes for protocols where byte identity matters, such as
    /// NUL-delimited Git paths. Human-readable diff content uses `output`.
    let rawOutput: Data?
    let output: String?
    /// Whether the output was cut off at the caller's byte bound.
    let capped: Bool
    /// Whether the supervisor signalled a live process specifically because
    /// stdout reached the caller's byte bound.
    let terminatedForOutputCap: Bool
    let failure: GitProcessFailure?
    /// Exit status when a Git subprocess launched and terminated.
    let terminationStatus: Int32?

    init(
        rawOutput: Data? = nil,
        output: String?,
        capped: Bool = false,
        terminatedForOutputCap: Bool = false,
        failure: GitProcessFailure? = nil,
        terminationStatus: Int32? = nil
    ) {
        self.rawOutput = rawOutput
        self.output = output
        self.capped = capped
        self.terminatedForOutputCap = terminatedForOutputCap
        self.failure = failure
        self.terminationStatus = terminationStatus
    }

    var timedOut: Bool { failure == .timedOut }
    var successOutput: String? { output }
}
