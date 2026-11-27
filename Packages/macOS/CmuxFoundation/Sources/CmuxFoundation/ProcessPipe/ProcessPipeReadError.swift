import Darwin
public import Foundation

/// A failed `read(2)`/`poll(2)` against a process pipe or socket descriptor,
/// carrying the failing operation name and the captured `errno`.
public struct ProcessPipeReadError: Error, Equatable, Sendable {
    /// The high-level operation that failed (e.g. `readDataToEndOfFile`).
    public let operation: String
    /// The `errno` value captured when the syscall failed.
    public let errnoCode: Int32

    /// Creates an error value; mirrors the original memberwise initializer.
    public init(operation: String, errnoCode: Int32) {
        self.operation = operation
        self.errnoCode = errnoCode
    }

    /// The `strerror(3)` text for ``errnoCode``.
    public var message: String {
        String(cString: strerror(errnoCode))
    }
}

extension ProcessPipeReadError: LocalizedError {
    public var errorDescription: String? {
        "\(operation) failed: \(message)"
    }
}
