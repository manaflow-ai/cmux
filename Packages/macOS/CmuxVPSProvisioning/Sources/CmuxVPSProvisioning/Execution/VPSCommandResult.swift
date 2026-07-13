internal import Foundation

/// Captured outcome of one local process invocation (ssh/scp).
public struct VPSCommandResult: Equatable, Sendable {
    /// Process exit status.
    public var status: Int32
    /// Captured stdout.
    public var stdout: String
    /// Captured stderr.
    public var stderr: String

    /// Creates a result.
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// The most useful single error line for user-facing messages: the last
    /// non-empty stderr line, else the last non-empty stdout line, else `nil`.
    public var bestErrorLine: String? {
        for text in [stderr, stdout] {
            let lines = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let last = lines.last {
                return last
            }
        }
        return nil
    }
}
