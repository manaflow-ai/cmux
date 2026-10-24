import CmuxNextCloud
import Foundation
import Testing

/// Prepaid cmux credits from the app (paid-plan.md section 5): the balance read, the payment page's
/// session, and the wait for a paid top-up, which asks the return page to grant it (so the balance
/// lands before the webhook does) and reads the balance until it rises.
@Suite struct CloudCreditsTests {
    @Test func theBalanceAndItsTopUpAmountsRead() throws {
        let data = Data(#"{"ok":true,"value":{"team":"team_1","balance_usd":3.5,"held_usd":0.5,"available_usd":3,"topup":{"link":"https://x/v1/credits/checkout/a.b","amounts_usd":[10,20,50,100]}}}"#.utf8)
        let balance = try CloudCreditsBalance(json: data)
        #expect(balance.availableUSD == 3)
        #expect(balance.amountsUSD == [10, 20, 50, 100])
        let none = try CloudCreditsBalance(json: Data(#"{"ok":true,"value":{"available_usd":0,"topup":null}}"#.utf8))
        #expect(none.amountsUSD.isEmpty)
    }

    @Test func thePaymentPagesSessionIsInItsPath() {
        #expect(CloudCreditsClient.checkoutSession(URL(string: "https://checkout.stripe.com/c/pay/cs_test_a1B2c3#fidkdWxOYHwn")!) == "cs_test_a1B2c3")
        #expect(CloudCreditsClient.checkoutSession(URL(string: "https://checkout.stripe.com/c/pay/ppage_1")!) == nil)
    }

    @Test func theWaitGrantsTheSessionAndEndsWhenTheBalanceRises() async throws {
        let reads = Reads(values: [0.4, 0.4, 20.4])
        let waiter = CloudCreditsWaiter(interval: .milliseconds(500), deadline: .seconds(60),
                                        balance: { try await reads.next() },
                                        grant: { session in await reads.granted(session) },
                                        sleep: { duration in await reads.slept(duration) })
        let outcome = try await waiter.wait(above: 0.4, session: "cs_test_a1")
        #expect(outcome == .rose(availableUSD: 20.4))
        #expect(await reads.grants == ["cs_test_a1", "cs_test_a1", "cs_test_a1"])
        #expect(await reads.sleeps == [.milliseconds(500), .milliseconds(500)])
    }

    @Test func theWaitEndsAtItsDeadline() async throws {
        let reads = Reads(values: Array(repeating: 0, count: 10))
        let waiter = CloudCreditsWaiter(interval: .seconds(1), deadline: .seconds(3),
                                        balance: { try await reads.next() }, grant: { _ in },
                                        sleep: { duration in await reads.slept(duration) })
        #expect(try await waiter.wait(above: 0, session: nil) == .timedOut(availableUSD: 0))
        #expect(await reads.sleeps.count == 3)
    }
}

/// A balance that answers `values` in turn, and what the waiter asked of it.
private actor Reads {
    var values: [Double]
    var grants: [String] = []
    var sleeps: [Duration] = []
    init(values: [Double]) { self.values = values }
    func next() -> Double { values.isEmpty ? 0 : values.removeFirst() }
    func granted(_ session: String) { grants.append(session) }
    func slept(_ duration: Duration) { sleeps.append(duration) }
}
