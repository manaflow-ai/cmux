public import Foundation

/// How a child process that ``AsyncProcess`` ran ended, and what it printed.
public struct ProcessOutcome: Sendable, Equatable {
    /// Its exit status, or the signal that ended it when ``exited`` is false.
    public var status: Int32
    /// Whether it exited on its own (`Process.TerminationReason.exit`), not by a signal.
    public var exited: Bool
    /// Its standard output (with standard error when the request merged them).
    public var output: Data
    /// Its standard error when the request kept it separate; empty otherwise.
    public var errorOutput: Data

    /// Whether it exited on its own with status 0.
    public var succeeded: Bool { exited && status == 0 }

    /// Its standard output as UTF-8 text (invalid bytes replaced).
    public var text: String { String(decoding: output, as: UTF8.self) }

    /// Creates an outcome (``AsyncProcess`` makes them; tests and fakes may too).
    public init(status: Int32, exited: Bool, output: Data, errorOutput: Data = Data()) {
        self.status = status
        self.exited = exited
        self.output = output
        self.errorOutput = errorOutput
    }
}
