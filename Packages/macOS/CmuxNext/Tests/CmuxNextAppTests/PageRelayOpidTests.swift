@testable import CmuxNextApp
import CmuxNextPages
import Testing

/// Decision 31 for relayed page mutations: without its own idempotency key, a page call's operation
/// id is the v2 idempotency key, so a resend after a reconnect replays the daemon's first answer.
struct PageRelayOpidTests {
    @Test func theOpidIsTheIdempotencyKeyWhenThePageSendsNone() {
        let context = PageCallContext(page: "cmux.history", opid: "h1:7")
        #expect(DaemonPageRelay.idempotencyKey(nil, context: context) == "h1:7")
        #expect(DaemonPageRelay.idempotencyKey("explicit", context: context) == "explicit", "the page's own key wins")
        #expect(DaemonPageRelay.idempotencyKey(nil, context: PageCallContext(page: "cmux.history")) == nil)
    }
}
