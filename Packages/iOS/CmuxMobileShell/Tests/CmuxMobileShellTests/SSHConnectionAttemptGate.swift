/// A transport that deliberately completes after cancellation, on command.
@MainActor
final class SSHConnectionAttemptGate {
    let started: AsyncStream<Void>
    private let starts: AsyncStream<Void>.Continuation
    private var result: CheckedContinuation<Int, any Error>?

    init() {
        (started, starts) = AsyncStream.makeStream()
    }

    func connect() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            result = continuation
            starts.yield(())
        }
    }

    func complete(_ value: Int) {
        let continuation = result
        result = nil
        continuation?.resume(returning: value)
    }

    func fail() {
        let continuation = result
        result = nil
        continuation?.resume(throwing: SSHConnectionAttemptFailure.transport)
    }

}
