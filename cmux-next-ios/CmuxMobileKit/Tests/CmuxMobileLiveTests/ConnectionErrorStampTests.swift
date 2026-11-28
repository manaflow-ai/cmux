import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-27: "Stale errors clear on fresh data." and "An error set by a timeout clears when the next
/// good data arrives, as in #62661." Each case: an error, then data, then what stands. A mutating call goes in a
/// `let` before `#expect`: the macro's expansion takes its operand as an immutable value.
@Suite struct ConnectionErrorStampTests {
    @Test func timeoutThenGoodDataClears() {
        var stamp = ConnectionErrorStamp()
        stamp.set("the Mac didn't send its workspaces", by: .timeout)
        #expect(stamp.message == "the Mac didn't send its workspaces")
        #expect(stamp.error?.setBy == .timeout)
        let cleared = stamp.fresh()
        #expect(cleared)
        #expect(stamp.message == nil)
    }

    @Test func fetchFailureThenGoodDataClears() {
        var stamp = ConnectionErrorStamp()
        let read = stamp.begin()
        let stood = stamp.set("list-workspaces reply is not an object", by: .fetch, startedAt: read)
        #expect(stood)
        let cleared = stamp.fresh()
        #expect(cleared)
        #expect(stamp.message == nil)
    }

    @Test func aFailureFromAReadOlderThanTheDataIsDropped() {
        var stamp = ConnectionErrorStamp()
        let read = stamp.begin()
        stamp.fresh()  // the list arrived (a later read, or a push) before this read failed
        let stood = stamp.set("daemon channel closed", by: .fetch, startedAt: read)
        #expect(!stood)
        #expect(stamp.message == nil)
    }

    @Test func aFailureAfterTheDataStands() {
        var stamp = ConnectionErrorStamp()
        stamp.fresh()
        let read = stamp.begin()
        let stood = stamp.set("daemon channel closed", by: .fetch, startedAt: read)
        #expect(stood)
        #expect(stamp.message == "daemon channel closed")
        #expect(stamp.error!.generation > stamp.freshAt)
    }

    @Test func aUserErrorIsNotClearedByData() {
        var stamp = ConnectionErrorStamp()
        stamp.set("you declined this Mac", by: .user)
        let cleared = stamp.fresh()
        #expect(!cleared)
        #expect(stamp.message == "you declined this Mac")
        stamp.clear()
        #expect(stamp.message == nil)
    }

    @Test func generationsOnlyGrow() {
        var stamp = ConnectionErrorStamp()
        let a = stamp.begin()
        stamp.set("x", by: .timeout)
        let set = stamp.error!.generation
        stamp.fresh()
        #expect(a < set)
        #expect(set < stamp.freshAt)
        #expect(stamp.generation == stamp.freshAt)
    }
}
