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
}
