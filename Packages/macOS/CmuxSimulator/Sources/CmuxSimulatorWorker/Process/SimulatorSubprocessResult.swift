import Darwin
import Foundation

struct SimulatorSubprocessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
    let errorWasTruncated: Bool
    let timedOut: Bool

    init(
        status: Int32,
        standardOutput: String,
        standardError: String,
        outputWasTruncated: Bool = false,
        errorWasTruncated: Bool = false,
        timedOut: Bool = false
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
        self.errorWasTruncated = errorWasTruncated
        self.timedOut = timedOut
    }

    /// Builds the result of a finished subprocess from its drained pipes.
    ///
    /// Throws when either pipe failed to read: the output before the failure
    /// is incomplete, and returning it with the exit status would report a
    /// broken read as a successful, possibly empty, result.
    static func completed(
        status: Int32,
        output: SimulatorPipeReadResult,
        error: SimulatorPipeReadResult,
        timedOut: Bool
    ) throws -> SimulatorSubprocessResult {
        if let failure = output.failure ?? error.failure {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    format: String(
                        localized: "simulator.failure.subprocessReadFailed",
                        defaultValue: "Reading Simulator subprocess output failed on %1$@: %2$@ (errno %3$@)."
                    ),
                    failure.streamName,
                    String(cString: strerror(failure.code)),
                    String(failure.code)
                )
            )
        }
        return SimulatorSubprocessResult(
            status: status,
            standardOutput: String(decoding: output.data, as: UTF8.self),
            standardError: String(decoding: error.data, as: UTF8.self),
            outputWasTruncated: output.truncated,
            errorWasTruncated: error.truncated,
            timedOut: timedOut
        )
    }
}
