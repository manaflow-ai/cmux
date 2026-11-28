@testable import CmuxMobileShell
import Foundation

/// Holds each open until the test completes it, including after cancellation.
@MainActor
final class MobileSSHTmuxOpeningGate {
    let attempts: AsyncStream<MobileSSHTmuxOpeningAttempt>
    private let continuation: AsyncStream<MobileSSHTmuxOpeningAttempt>.Continuation
    private(set) var count = 0

    init() {
        (attempts, continuation) = AsyncStream.makeStream(of: MobileSSHTmuxOpeningAttempt.self)
    }

    func open(session: String) async throws -> MobileSSHTmuxControlClient {
        try await withCheckedThrowingContinuation { completion in
            count += 1
            continuation.yield(MobileSSHTmuxOpeningAttempt(session: session, completion: completion))
        }
    }
}
