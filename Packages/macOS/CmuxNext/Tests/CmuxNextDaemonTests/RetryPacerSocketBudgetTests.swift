import Foundation
import Testing
@testable import CmuxNextDaemon

/// The timed retries belong to one socket: a socket that replaced the one that spent them gets
/// its own, because its change can come while an attempt runs and then wakes nothing (a restarted
/// daemon still binding, or answering with an error while it starts). Before, the budget stayed
/// spent and the reader parked with no timer until the next app activation. Each renewal counts
/// toward the crash-loop limit, so a daemon that keeps replacing its socket gets a bounded number.
@Suite struct RetryPacerSocketBudgetTests {
    private func socket(_ inode: ino_t) -> RetryWake.Identity { RetryWake.Identity(device: 1, inode: inode) }

    @Test func aReplacedSocketGetsTimedRetriesOfItsOwn() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1))
        #expect(pacer.failed(at: socket(1)) != nil)
        #expect(pacer.failed(at: socket(1)) == nil, "the stale socket's budget was not spent")
        #expect(pacer.failed(at: socket(2)) != nil, "the socket that replaced it got no timed retry")
    }

    @Test func renewalsStopAtTheCrashLoopLimit() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1, socketRetries: 2))
        #expect(pacer.failed(at: socket(1)) != nil)
        #expect(pacer.failed(at: socket(1)) == nil)
        #expect(pacer.failed(at: socket(2)) != nil)
        #expect(pacer.failed(at: socket(2)) == nil)
        #expect(pacer.failed(at: socket(3)) != nil)
        #expect(pacer.failed(at: socket(3)) == nil)
        #expect(!pacer.wakesOnSocket)
        #expect(pacer.failed(at: socket(4)) == nil, "a daemon that keeps replacing its socket was retried without bound")
    }

    @Test func aSuccessForgetsTheSocket() {
        var pacer = RetryPacer(RetryPolicy(initial: .milliseconds(250), maximum: .seconds(30), timedRetries: 1, socketRetries: 1))
        #expect(pacer.failed(at: socket(1)) != nil)
        #expect(pacer.failed(at: socket(2)) != nil)
        #expect(!pacer.wakesOnSocket)
        pacer.reset()
        #expect(pacer.wakesOnSocket)
        #expect(pacer.failed(at: socket(3)) != nil)
        #expect(pacer.failed(at: socket(4)) != nil, "a success did not renew the crash-loop limit")
    }
}
