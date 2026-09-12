import Foundation
import os
import Testing
@testable import CmuxCLISocketAuth

/// Exercises the deadline boundary that decides whether a deferred credential
/// lookup is complete and may be suppressed on a later operation.
/// Per-test locks bridge synchronous Sendable clock callbacks without sleeping.
@Suite
struct SocketCredentialResolutionAttemptTests {
    @Test(arguments: [true, false])
    func lateResolutionRemainsRetryable(firstLookupReturnsPassword: Bool) throws {
        let clock = OSAllocatedUnfairLock<Date>(
            initialState: Date(timeIntervalSince1970: 1_000)
        )
        var providerCalls = 0
        var attempt = SocketCredentialResolutionAttempt(now: {
            clock.withLock { $0 }
        })
        let firstDeadline = clock.withLock { $0.addingTimeInterval(1) }

        #expect(throws: SocketCredentialResolutionAttempt.Failure.self) {
            try attempt.resolve(
                provider: { _ in
                    providerCalls += 1
                    clock.withLock { $0.addTimeInterval(2) }
                    return firstLookupReturnsPassword ? "late-password" : nil
                },
                deadline: firstDeadline
            )
        }
        #expect(!attempt.isCompleted)
        #expect(providerCalls == 1)

        let secondDeadline = clock.withLock { $0.addingTimeInterval(1) }
        let secondResult = try attempt.resolve(
            provider: { _ in
                providerCalls += 1
                return "fresh-password"
            },
            deadline: secondDeadline
        )

        #expect(secondResult == "fresh-password")
        #expect(attempt.isCompleted)
        #expect(providerCalls == 2)
    }

    @Test(arguments: [true, false])
    func inBudgetResolutionCompletesAndSuppressesDuplicateLookup(
        returnsPassword: Bool
    ) throws {
        let clock = OSAllocatedUnfairLock<Date>(
            initialState: Date(timeIntervalSince1970: 2_000)
        )
        var providerCalls = 0
        var attempt = SocketCredentialResolutionAttempt(now: {
            clock.withLock { $0 }
        })
        let deadline = clock.withLock { $0.addingTimeInterval(1) }

        let firstResult = try attempt.resolve(
            provider: { _ in
                providerCalls += 1
                return returnsPassword ? "password" : nil
            },
            deadline: deadline
        )

        #expect(firstResult == (returnsPassword ? "password" : nil))
        #expect(attempt.isCompleted)

        let secondResult = try attempt.resolve(
            provider: { _ in
                providerCalls += 1
                return "unexpected-second-password"
            },
            deadline: deadline
        )

        #expect(secondResult == nil)
        #expect(providerCalls == 1)
    }

    @Test(arguments: [0.0, -1.0])
    func expiredResolutionDoesNotReadProviderOrComplete(offset: TimeInterval) throws {
        let clock = OSAllocatedUnfairLock<Date>(
            initialState: Date(timeIntervalSince1970: 3_000)
        )
        var providerCalls = 0
        var attempt = SocketCredentialResolutionAttempt(now: {
            clock.withLock { $0 }
        })

        #expect(throws: SocketCredentialResolutionAttempt.Failure.self) {
            try attempt.resolve(
                provider: { _ in
                    providerCalls += 1
                    return "must-not-read"
                },
                deadline: clock.withLock { $0.addingTimeInterval(offset) }
            )
        }
        #expect(providerCalls == 0)
        #expect(!attempt.isCompleted)
    }

    @Test
    func noDeadlineAllowsOneCompletion() throws {
        let clock = OSAllocatedUnfairLock<Date>(
            initialState: Date(timeIntervalSince1970: 4_000)
        )
        var providerCalls = 0
        var observedDeadline: Date?
        var attempt = SocketCredentialResolutionAttempt(now: {
            clock.withLock { $0 }
        })

        let firstResult = try attempt.resolve(
            provider: { deadline in
                providerCalls += 1
                observedDeadline = deadline
                return "password"
            },
            deadline: nil
        )
        let secondResult = try attempt.resolve(
            provider: { _ in
                providerCalls += 1
                return "unexpected-second-password"
            },
            deadline: nil
        )

        #expect(firstResult == "password")
        #expect(secondResult == nil)
        #expect(observedDeadline == nil)
        #expect(attempt.isCompleted)
        #expect(providerCalls == 1)
    }
}
