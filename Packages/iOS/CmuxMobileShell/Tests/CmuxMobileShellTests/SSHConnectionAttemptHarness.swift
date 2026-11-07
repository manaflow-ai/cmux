@testable import CmuxMobileShell
import Foundation

@MainActor
final class SSHConnectionAttemptHarness {
    let attempts = MobileSSHConnectionAttempts<Int>()
    let hostID = UUID()
    var published: [Int] = []
    var discarded: [Int] = []
    var failures = 0
    let entered: AsyncStream<Void>
    private let entries: AsyncStream<Void>.Continuation

    init() {
        (entered, entries) = AsyncStream.makeStream()
    }

    func connection(_ gate: SSHConnectionAttemptGate) async throws -> Int {
        entries.yield(())
        return try await attempts.connection(
            hostID: hostID,
            connect: { try await gate.connect() },
            discard: { self.discarded.append($0) },
            connected: { self.published.append($0) },
            failed: { _ in self.failures += 1 }
        )
    }
}
