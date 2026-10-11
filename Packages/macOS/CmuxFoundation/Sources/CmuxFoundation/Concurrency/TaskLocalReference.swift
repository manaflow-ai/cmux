/// Holds an async `@TaskLocal` payload behind a reference.
///
/// cmux deploys to macOS 14, where an async `TaskLocal.withValue` runs Swift's
/// back-deployed fallback. Built with Xcode 26, that fallback copies a value
/// whose size is only known at run time (any struct holding Foundation's
/// `UUID`, `Date` or `URL`, or another resilient type) into a task-allocator
/// temporary, pushes the task-local item, and then frees the temporary first.
/// The task allocator is last-in-first-out, so the process aborts with "freed
/// pointer was not the last allocation". A class reference has a fixed size,
/// so binding one never takes that path.
///
/// Declare the key as `@TaskLocal static var key: TaskLocalReference<Value>?`
/// and bind it with `withReferencedValue(_:isolation:file:line:operation:)`.
public final class TaskLocalReference<Value: Sendable>: Sendable {
    /// The bound payload.
    public let value: Value

    /// Wraps a payload for task-local storage.
    ///
    /// - Parameter value: The payload to bind.
    public init(_ value: Value) {
        self.value = value
    }
}

extension TaskLocal {
    /// Binds `value` behind a ``TaskLocalReference`` for the duration of
    /// `operation`, restoring the enclosing binding when it returns or throws.
    ///
    /// Passing `nil` binds an explicit empty scope, which hides a value bound
    /// by an enclosing scope.
    ///
    /// - Parameters:
    ///   - value: The payload to bind, or `nil` to clear the enclosing binding.
    ///   - isolation: The caller's isolation, which `operation` keeps.
    ///   - file: The caller's file, reported by misuse diagnostics.
    ///   - line: The caller's line, reported by misuse diagnostics.
    ///   - operation: The work that observes the binding.
    /// - Returns: The value `operation` returns.
    @inlinable
    @discardableResult
    public func withReferencedValue<Referenced: Sendable, Result>(
        _ value: Referenced?,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #fileID,
        line: UInt = #line,
        operation: () async throws -> Result
    ) async rethrows -> Result where Value == TaskLocalReference<Referenced>? {
        try await withValue(
            value.map(TaskLocalReference.init),
            operation: operation,
            isolation: isolation,
            file: file,
            line: line
        )
    }
}
