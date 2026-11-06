@testable import CmuxNextCloud
import Testing

/// A Cloud start's second link wait (`CloudWait.linkedAgain`, as `CloudStartSession.connected` calls it) under a late
/// link, a Retry or cancellation that races it, an account switch and a relaunch: it dials at most once more, only
/// for the account that asked, and only when the link it waited on does not hold.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudLinkedAgainTests {
    /// The start's view of one machine link: whether it holds and whether its last end is one a dial can help.
    @MainActor final class Link {
        var held = false
        var ended = false
        var waits = 0
        var dials = 0
        var account: [String?] = ["user-1", "team-1"]
        let asked: [String?] = ["user-1", "team-1"]
        /// What the start's `redialable` reads: the asking account is still signed in and the link ended.
        var redialable: Bool { account == asked && ended }
    }

    /// A link that came up at the end of the first wait but dropped before the start read it: `linkUp`'s own redial
    /// is over by then, so the start dials once more and waits again. A wait that ran out with the link down
    /// (the receiver answers late) gets that dial too.
    @Test func aLinkThatCameUpLateButDroppedIsDialedOnceMore() async {
        let link = Link()
        let up = await CloudWait.linkedAgain({ link.waits += 1; if link.waits == 1 { link.ended = true }; return true },
                                             held: { link.held }, redialable: { link.redialable },
                                             again: { link.dials += 1; link.held = true })
        #expect(up)
        #expect((link.waits, link.dials) == (2, 1))

        let late = Link()
        late.ended = true
        let answered = await CloudWait.linkedAgain({ late.waits += 1; return late.dials > 0 }, held: { late.dials > 0 },
                                                   redialable: { late.redialable }, again: { late.dials += 1 })
        #expect(answered, "the receiver that answered after the first wait's deadline is reached by the second")
        #expect((late.waits, late.dials) == (2, 1))
    }

    /// The person's Retry while the first wait runs brings the link back: the start reads it held and adds no dial
    /// of its own. A Retry during the start's second wait does not make it dial a third time. A cancelled start
    /// dials nothing more.
    @Test func aRetryOrCancellationThatRacesTheWaitAddsNoDial() async {
        let link = Link()
        link.ended = true
        #expect(await CloudWait.linkedAgain({ link.waits += 1; link.held = true; return true }, held: { link.held },
                                            redialable: { link.redialable }, again: { link.dials += 1 }))
        #expect((link.waits, link.dials) == (1, 0))

        let raced = Link()
        raced.ended = true
        #expect(!(await CloudWait.linkedAgain({ raced.waits += 1; return true }, held: { raced.held },
                                              redialable: { raced.redialable }, again: { raced.dials += 1 })))
        #expect((raced.waits, raced.dials) == (2, 1), "the second wait's answer stands, however many Retries ran under it")

        let cancelled = Link()
        cancelled.ended = true
        let start = Task { @MainActor in
            await CloudWait.linkedAgain({ cancelled.waits += 1; withUnsafeCurrentTask { $0?.cancel() }; return false },
                                        held: { cancelled.held }, redialable: { cancelled.redialable }, again: { cancelled.dials += 1 })
        }
        #expect(await start.value == false)
        #expect((cancelled.waits, cancelled.dials) == (1, 0))
    }

    /// A sign-out or team switch during the first wait: the one more dial (which may resume the machine) is not made
    /// for an account that no longer asks.
    @Test func anAccountSwitchDuringTheWaitIsNotDialedAgain() async {
        let link = Link()
        link.ended = true
        let up = await CloudWait.linkedAgain({ link.waits += 1; link.account = ["user-2", "team-2"]; return false },
                                             held: { link.held }, redialable: { link.redialable }, again: { link.dials += 1 })
        #expect(!up)
        #expect((link.waits, link.dials) == (1, 0))
    }

    /// Nothing of the wait outlives its start: after a relaunch the start that runs again gets its own one more dial,
    /// and no more than one.
    @Test func aStartAfterARelaunchGetsItsOwnOneMoreDial() async {
        let link = Link()
        link.ended = true
        for _ in 0..<2 {
            link.waits = 0
            link.dials = 0
            #expect(!(await CloudWait.linkedAgain({ link.waits += 1; return false }, held: { link.held },
                                                  redialable: { link.redialable }, again: { link.dials += 1 })))
            #expect((link.waits, link.dials) == (2, 1))
        }
    }
}
