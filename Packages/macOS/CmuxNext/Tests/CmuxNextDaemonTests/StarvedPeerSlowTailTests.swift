import Foundation
import Testing
@testable import CmuxNextDaemon

/// A remote or Cloud machine's daemon that was starved (a SIGSTOPped or swapped-out Mac, a VM
/// with no CPU) or unreachable past the timed budget comes back with no local event at all. Before,
/// `.reconnect` and `.firstConnect` waited for an event only once the ten timed retries (~80 s) were
/// spent, so a peer starved longer than that was never asked again (handbook
/// `starved-app-never-comes-back`: a give-up is never terminal). Now they keep one attempt per
/// ``RetryPolicy/starvedPeerTail`` for as long as the peer fails, and still read offline.
@Suite struct StarvedPeerSlowTailTests {
    @Test(arguments: [("reconnect", RetryPolicy.reconnect), ("firstConnect", RetryPolicy.firstConnect)])
    func aPeerStarvedPastTheBudgetIsAskedAgainEveryFiveMinutes(name: String, policy: RetryPolicy) {
        var pacer = RetryPacer(policy)
        for _ in 0..<policy.timedRetries { #expect(pacer.failed() != nil) }
        #expect(!pacer.spentTimedRetries)
        // An hour of a peer that stays starved: every failure still arms a timer.
        var asked = 0
        for _ in 0..<12 {
            let delay = pacer.failed()
            #expect(delay == RetryPolicy.starvedPeerTail, "\(name): a starved peer was left for an event only")
            #expect(!pacer.waitsForEventOnly, "\(name): the wait armed no timer")
            #expect(pacer.spentTimedRetries, "\(name): a peer past its budget no longer reads offline")
            if delay != nil { asked += 1 }
        }
        print("starved-peer \(name): attempts in the hour after the timed budget: \(asked) (before: 0)")
        #expect(asked == 12)
        // The peer answers: the budget is whole again.
        pacer.reset()
        #expect(!pacer.spentTimedRetries)
        #expect(pacer.failed() != nil)
    }

    @Test func aPolicyWithNoSlowTailStillWaitsForAnEventOnly() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1))
        #expect(pacer.failed() != nil)
        #expect(pacer.failed() == nil)
        #expect(pacer.waitsForEventOnly)
        #expect(pacer.spentTimedRetries)
    }
}
