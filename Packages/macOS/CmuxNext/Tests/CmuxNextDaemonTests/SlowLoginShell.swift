import Foundation
import Synchronization

/// A stand-in for `$SHELL -l -i -c 'env -0'` that answers only when the test
/// says so: each capture waits for the next `answer(_:)`. Records the
/// deadline each capture was given.
final class SlowLoginShell: Sendable {
    private let answers: AsyncStream<[String: String]?>
    private let continuation: AsyncStream<[String: String]?>.Continuation
    private let deadlines = Mutex<[Duration]>([])

    init() {
        let (answers, continuation) = AsyncStream.makeStream(of: [String: String]?.self, bufferingPolicy: .bufferingOldest(8))
        self.answers = answers
        self.continuation = continuation
    }

    /// The capture closure for `LoginEnvironmentCache`.
    func capture(_ timeout: Duration) async -> [String: String]? {
        deadlines.withLock { $0.append(timeout) }
        for await answer in answers { return answer }
        return nil
    }

    /// Lets one capture finish with `environment` (nil: timed out).
    func answer(_ environment: [String: String]?) { continuation.yield(environment) }

    /// Ends every waiting capture (test teardown).
    func close() { continuation.finish() }

    var capturedDeadlines: [Duration] { deadlines.withLock { $0 } }
}
