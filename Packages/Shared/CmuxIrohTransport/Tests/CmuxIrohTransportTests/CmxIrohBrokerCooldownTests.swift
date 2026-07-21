import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohBrokerCooldownTests {
    private let start = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func recordsAndReportsRemainingWholeSeconds() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 600, now: start)

        let remaining = cooldown.remainingSeconds(
            accountID: "a",
            now: start.addingTimeInterval(0.5)
        )
        #expect(remaining == 600)
        #expect(cooldown.remainingSeconds(
            accountID: "a",
            now: start.addingTimeInterval(599.2)
        ) == 1)
    }

    @Test
    func expiresOnReadAndStaysClear() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 10, now: start)

        #expect(cooldown.remainingSeconds(
            accountID: "a",
            now: start.addingTimeInterval(10)
        ) == nil)
        #expect(cooldown.retryAt == nil)
        #expect(cooldown.remainingSeconds(accountID: "a", now: start) == nil)
    }

    @Test
    func overlappingDirectivesKeepTheLaterFloor() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 600, now: start)
        cooldown.record(accountID: "a", retryAfterSeconds: 10, now: start.addingTimeInterval(5))

        #expect(cooldown.remainingSeconds(
            accountID: "a",
            now: start.addingTimeInterval(5)
        ) == 595)
    }

    @Test
    func laterDirectiveExtendsTheFloor() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 10, now: start)
        cooldown.record(accountID: "a", retryAfterSeconds: 600, now: start.addingTimeInterval(5))

        #expect(cooldown.remainingSeconds(
            accountID: "a",
            now: start.addingTimeInterval(6)
        ) == 599)
    }

    @Test
    func accountSwitchReplacesTheFloor() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 600, now: start)
        cooldown.record(accountID: "b", retryAfterSeconds: 30, now: start)

        #expect(cooldown.remainingSeconds(accountID: "a", now: start) == nil)
        #expect(cooldown.remainingSeconds(accountID: "b", now: start) == 30)
    }

    @Test
    func scopedClearOnlyDropsMatchingAccount() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 600, now: start)

        cooldown.clear(accountID: "b")
        #expect(cooldown.remainingSeconds(accountID: "a", now: start) == 600)

        cooldown.clear(accountID: "a")
        #expect(cooldown.remainingSeconds(accountID: "a", now: start) == nil)
    }

    @Test
    func nonPositiveDirectiveStillArmsOneSecond() {
        var cooldown = CmxIrohBrokerCooldown()
        cooldown.record(accountID: "a", retryAfterSeconds: 0, now: start)
        #expect(cooldown.remainingSeconds(accountID: "a", now: start) == 1)
    }

    @Test
    func cooldownErrorProvidesRetryAfterAndFailureKind() {
        let error = CmxIrohBrokerCooldownError(retryAfterSeconds: 42)
        #expect(error.retryAfterSeconds == 42)
        #expect(error.diagnosticFailureKind == .policyUnavailable)
        #expect(CmxIrohBrokerCooldownError(retryAfterSeconds: 0).retryAfterSeconds == 1)
    }
}
