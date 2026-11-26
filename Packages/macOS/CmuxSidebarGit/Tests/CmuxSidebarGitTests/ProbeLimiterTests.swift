import Foundation
import Testing
@testable import CmuxSidebarGit

@Suite struct ProbeLimiterTests {
    /// The limiter admits `limit` concurrent holders; the next acquirer waits
    /// until a permit is released.
    @Test func limiterCapsConcurrentHolders() async throws {
        let limiter = WorkspaceGitMetadataProbeLimiter(limit: 2)
        #expect(await limiter.acquire())
        #expect(await limiter.acquire())

        let third = Task {
            await limiter.acquire()
        }
        // The third acquirer must still be parked; release one permit and it
        // completes with success.
        await limiter.release()
        #expect(await third.value)
    }

    /// A cancelled waiter resolves to `false` without consuming a permit.
    @Test func cancelledWaiterReturnsFalse() async throws {
        let limiter = WorkspaceGitMetadataProbeLimiter(limit: 1)
        #expect(await limiter.acquire())

        let waiter = Task {
            await limiter.acquire()
        }
        // Let the waiter park, then cancel it.
        await Task.yield()
        waiter.cancel()
        #expect(await waiter.value == false)

        // The held permit is still released normally and reusable.
        await limiter.release()
        #expect(await limiter.acquire())
    }
}
