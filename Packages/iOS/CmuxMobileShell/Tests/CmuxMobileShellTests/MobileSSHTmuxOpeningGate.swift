@testable import CmuxMobileShell
import Foundation

/// Holds each open until the test completes it, including after cancellation.
@MainActor
final class MobileSSHTmuxOpeningGate {
    struct Attempt {
        let session: String
        let completion: CheckedContinuation<MobileSSHTmuxControlClient, any Error>
    }

    let attempts: AsyncStream<Attempt>
    private let continuation: AsyncStream<Attempt>.Continuation
    private(set) var count = 0

    init() {
        (attempts, continuation) = AsyncStream.makeStream(of: Attempt.self)
    }

    func open(session: String) async throws -> MobileSSHTmuxControlClient {
        try await withCheckedThrowingContinuation { completion in
            count += 1
            continuation.yield(Attempt(session: session, completion: completion))
        }
    }
}
