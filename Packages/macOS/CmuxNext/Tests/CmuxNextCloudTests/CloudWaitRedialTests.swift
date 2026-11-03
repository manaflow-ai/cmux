import Foundation
@testable import CmuxNextCloud
import Testing

/// A Cloud start's wait for its machine (`CloudMove.connected`, #32469): an ended link is dialed
/// again before each try, and the tries stop at the first one that sees the link up.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudWaitRedialTests {
    @MainActor
    private final class Link {
        var redials = 0
        var upAfterRedials = Int.max
        var up: Bool { redials >= upAfterRedials }
    }

    @Test func redialsBeforeEachTryAndStopsWhenTheLinkIsUp() async {
        let link = Link()
        link.upAfterRedials = 2
        let up = await CloudWait.holds(tries: 6, each: .milliseconds(30), redial: { link.redials += 1 }, until: { link.up })
        #expect(up)
        #expect(link.redials == 2, "the tries went on after the link was up, or did not redial before a try")
    }

    @Test func endsAfterTheLastTryWhenTheLinkNeverComesUp() async {
        let link = Link()
        let up = await CloudWait.holds(tries: 3, each: .milliseconds(10), redial: { link.redials += 1 }, until: { link.up })
        #expect(!up)
        #expect(link.redials == 3)
    }

    @Test func onlyADownOrRevokedLinkIsADrop() {
        #expect(CloudLinkError.isDrop(CloudLinkError.disconnected(reason: "")))
        #expect(CloudLinkError.isDrop(CloudLinkError.revoked(reason: "x")))
        #expect(!CloudLinkError.isDrop(CloudLinkError.failed(code: "c", message: "")))
        #expect(!CloudLinkError.isDrop(CloudLinkError.unsafeSocket("x")))
        #expect(!CloudLinkError.isDrop(CloudAppOpError(code: "c", message: "m")))
    }
}
