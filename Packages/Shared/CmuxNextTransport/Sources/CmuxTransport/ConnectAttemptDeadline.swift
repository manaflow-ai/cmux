/// Races one admission attempt against an injected deadline.
public struct ConnectAttemptDeadline: Sendable {
    /// Creates a deadline runner with no shared mutable state.
    public init() {}

    /// Runs the attempt, drains both outcomes, and closes an unclaimed admission.
    ///
    /// The deadline operation normally waits on a cancellable clock. Both
    /// operations must respond to cancellation, including waking native I/O.
    /// A losing attempt may still return an admitted connection; that connection
    /// is closed before this method throws. A winning admission is handed to the
    /// caller only when the parent task has not been cancelled.
    ///
    /// ```swift
    /// let outcome = try await ConnectAttemptDeadline().run(
    ///     connect: dialAndAdmit,
    ///     timeout: { try await ContinuousClock().sleep(for: .seconds(6)) })
    /// ```
    ///
    /// - Parameters:
    ///   - connect: Dials and admits one connection, cleaning up on failure.
    ///   - timeout: Waits for the deadline; cancellation must end this wait.
    /// - Returns: The winning result, transferring an admitted connection to the caller.
    /// - Throws: The attempt error, cancellation, or ``TransportError/dialTimeout``.
    public func run(
        connect: @escaping @Sendable () async throws -> ConnectAttemptResult,
        timeout: @escaping @Sendable () async throws -> Void
    ) async throws -> ConnectAttemptResult {
        let result: Result<ConnectAttemptResult, any Error> = await withTaskGroup(
            of: Result<ConnectAttemptResult, any Error>.self
        ) { group in
            group.addTask {
                do { return .success(try await connect()) }
                catch { return .failure(error) }
            }
            group.addTask {
                do {
                    try await timeout()
                    return .failure(TransportError.dialTimeout)
                } catch { return .failure(error) }
            }
            guard let first = await group.next() else {
                return .failure(TransportError.dialTimeout)
            }
            group.cancelAll()
            // Throwing out of a task group waits for children but discards
            // their values. Drain explicitly so a late admission stays owned.
            for await losing in group { await closeAdmission(in: losing) }
            return first
        }
        if Task.isCancelled {
            await closeAdmission(in: result)
            throw CancellationError()
        }
        return try result.get()
    }

    private func closeAdmission(in result: Result<ConnectAttemptResult, any Error>) async {
        guard case .success(.admitted(let connection, _)) = result else { return }
        await connection.closeAll(reason: ConnectionTermination(code: "dial-cancelled"))
    }
}
