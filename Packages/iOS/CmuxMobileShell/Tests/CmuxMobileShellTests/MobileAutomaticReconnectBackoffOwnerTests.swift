import Foundation
import Testing
@testable import CmuxMobileShell

@Suite
struct MobileAutomaticReconnectBackoffOwnerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func preservesLongestDeadlineForSameAccount() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        let first = owner.record(accountID: "account-a", retryAfterSeconds: 120, now: now)
        let shorter = owner.record(accountID: "account-a", retryAfterSeconds: 30, now: now)
        let blockedBeforeDeadline = owner.isBlocked(
            accountID: "account-a",
            now: now.addingTimeInterval(119)
        )
        let blockedAtDeadline = owner.isBlocked(
            accountID: "account-a",
            now: now.addingTimeInterval(120)
        )

        #expect(shorter == first)
        #expect(blockedBeforeDeadline)
        #expect(!blockedAtDeadline)
    }

    @Test
    func accountBoundaryDoesNotApplyAnotherAccountsDeadline() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        _ = owner.record(accountID: "account-a", retryAfterSeconds: 120, now: now)
        let otherAccountBlocked = owner.isBlocked(accountID: "account-b", now: now)
        let owningAccountBlocked = owner.isBlocked(accountID: "account-a", now: now)

        #expect(!otherAccountBlocked)
        #expect(owningAccountBlocked)
    }

    @Test
    func normalizesInvalidDelayWithoutShorteningValidServerAuthority() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        let minimum = owner.record(accountID: "account-a", retryAfterSeconds: 0, now: now)
        owner.clear()
        let fullDay = owner.record(accountID: "account-a", retryAfterSeconds: 86_400, now: now)

        #expect(minimum == now.addingTimeInterval(1))
        #expect(fullDay == now.addingTimeInterval(86_400))
    }

    @Test
    func transientFailuresBackOffExponentiallyAndKeepServerAuthority() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        let serverDeadline = owner.record(
            accountID: "account-a",
            retryAfterSeconds: 120,
            now: now
        )
        var transientDeadlines: [Date] = []
        for offset in 0 ..< 7 {
            transientDeadlines.append(owner.recordTransientFailure(
                accountID: "account-a",
                now: now.addingTimeInterval(TimeInterval(offset))
            ))
        }

        #expect(transientDeadlines == Array(repeating: serverDeadline, count: 7))
        #expect(owner.transientFailureCount == 7)
        #expect(owner.retryAt == serverDeadline)
    }

    @Test
    func transientBackoffProgressesToSixtySecondsWithoutResettingAtDeadline() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        let expectedDelays: [TimeInterval] = [2, 4, 8, 16, 32, 60, 60]

        for (index, expectedDelay) in expectedDelays.enumerated() {
            let failureTime = now.addingTimeInterval(TimeInterval(index * 100))
            let deadline = owner.recordTransientFailure(
                accountID: "account-a",
                now: failureTime
            )
            let blockedBeforeDeadline = owner.isBlocked(
                accountID: "account-a",
                now: deadline.addingTimeInterval(-1)
            )
            let blockedAtDeadline = owner.isBlocked(
                accountID: "account-a",
                now: deadline
            )
            #expect(deadline == failureTime.addingTimeInterval(expectedDelay))
            #expect(blockedBeforeDeadline)
            #expect(!blockedAtDeadline)
        }

        #expect(owner.transientFailureCount == expectedDelays.count)
    }

    @Test
    func clearingTransientCooldownPreservesServerFloorAndFailureCount() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        let serverDeadline = owner.record(
            accountID: "account-a",
            retryAfterSeconds: 120,
            now: now
        )
        _ = owner.recordTransientFailure(accountID: "account-a", now: now)

        owner.clearTransientCooldown(accountID: "account-a")

        let stillBlocked = owner.isBlocked(
            accountID: "account-a",
            now: now.addingTimeInterval(119)
        )
        #expect(owner.retryAt == serverDeadline)
        #expect(owner.transientFailureCount == 1)
        #expect(stillBlocked)
    }

    @Test
    func successfulConnectionResetsAllBackoffForOnlyItsAccount() {
        var owner = MobileAutomaticReconnectBackoffOwner()
        _ = owner.recordTransientFailure(accountID: "account-a", now: now)

        owner.clear(accountID: "account-b")
        #expect(owner.accountID == "account-a")
        #expect(owner.transientFailureCount == 1)

        owner.clear(accountID: "account-a")
        #expect(owner.accountID == nil)
        #expect(owner.retryAt == nil)
        #expect(owner.transientFailureCount == 0)
    }
}
