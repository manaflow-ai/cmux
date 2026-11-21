@testable import CmuxNextCloud
import Testing

/// start-session's anchor wait under a machine daemon restart (`CloudWait.relinkedOnce`).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudRelinkedOnceTests {
    private struct NotConnected: Error {}

    /// The anchor wait's view of one link: its connection epoch, whether it holds, and what ran.
    @MainActor final class Anchor {
        var epoch = 1
        var held = true
        var tries = 0
        var relinks = 0
    }

    /// start-session's anchor wait under a daemon restart (`CloudWait.relinkedOnce`, prod 2026-11-07: a new VM's updater
    /// restarted its daemon and the start answered "didn't connect" 13 s in): a failure while the link dropped relinks and
    /// looks once more; a failure with the link up, or a relink that fails, throws as it is.
    @Test func anAnchorWaitThatLostItsLinkRelinksAndLooksOnceMore() async throws {
        let restarted = Anchor()
        let found = try await CloudWait.relinkedOnce(epoch: { restarted.epoch }, held: { restarted.held },
                                                     relink: { restarted.relinks += 1; restarted.held = true; return true }) {
            restarted.tries += 1
            if restarted.tries == 1 { restarted.epoch += 1; restarted.held = false; throw NotConnected() } // the daemon restarted under the wait
            return "workspace-1"
        }
        #expect(found == "workspace-1")
        #expect((restarted.tries, restarted.relinks) == (2, 1))

        let steady = Anchor()
        await #expect(throws: NotConnected.self) {
            try await CloudWait.relinkedOnce(epoch: { steady.epoch }, held: { steady.held }, relink: { steady.relinks += 1; return true }) {
                steady.tries += 1
                throw NotConnected()
            }
        }
        #expect((steady.tries, steady.relinks) == (1, 0), "a link that held is not dialed again")

        let lost = Anchor()
        lost.held = false
        await #expect(throws: NotConnected.self) {
            try await CloudWait.relinkedOnce(epoch: { lost.epoch }, held: { lost.held }, relink: { lost.relinks += 1; return false }) {
                lost.tries += 1
                throw NotConnected()
            }
        }
        #expect((lost.tries, lost.relinks) == (1, 1), "a relink that fails looks no more")
    }
}
