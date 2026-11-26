#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Testing

/// ``blockingCall(_:fileID:line:_:)`` opens its call for the hang watcher while it runs on the main
/// thread (Chrome's `HangWatcher` names the `ScopedBlockingCall` a hung thread is in), and only there.
/// Builds with the detector only: in Release no call is ever open.
@Suite(.serialized)
struct BlockingOpenCallTests {
    @MainActor @Test func aCheckedCallOnTheMainThreadIsOpenWhileItRuns() {
        #expect(BlockingOpenCall.current() == .none)
        let line: UInt = #line + 1
        let inside = Self.recorded { blockingCall(.fileIO) { BlockingOpenCall.current() } }
        #expect(inside.kind == .fileIO)
        #expect(inside.location == "CmuxNextCompatTests/BlockingOpenCallTests.swift:\(line)")
        #expect(inside.summary == "file-io at CmuxNextCompatTests/BlockingOpenCallTests.swift:\(line)")
        #expect(BlockingOpenCall.current() == .none, "the call closes when its body returns")
    }

    @MainActor @Test func aNestedCallReplacesTheOuterOneUntilItReturns() {
        let (inner, outer) = Self.recorded {
            blockingCall(.syncWait, line: 7) {
                (blockingCall(.fileIO, line: 9) { BlockingOpenCall.current() }, BlockingOpenCall.current())
            }
        }
        #expect(inner.summary == "file-io at CmuxNextCompatTests/BlockingOpenCallTests.swift:9")
        #expect(outer.summary == "sync-wait at CmuxNextCompatTests/BlockingOpenCallTests.swift:7")
        #expect(BlockingOpenCall.current() == .none)
    }

    @MainActor @Test func aThrowingCallClosesToo() {
        struct Failed: Error {}
        #expect(throws: Failed.self) { try Self.recorded { try blockingCall(.fileIO) { throw Failed() } } }
        #expect(BlockingOpenCall.current() == .none)
    }

    /// The open call is the main thread's: a checked call on another thread never becomes it,
    /// whatever the main thread is doing meanwhile (line 1 is used nowhere else).
    @Test func aCallOffTheMainThreadIsNeverTheOpenCall() async {
        let inside = await Task.detached { blockingCall(.fileIO, line: 1) { BlockingOpenCall.current() } }.value
        #expect(inside.location?.hasSuffix("BlockingOpenCallTests.swift:1") != true)
    }

    @Test func theWordsRoundTrip() {
        let packed = BlockingOpenCall.pack(.processSpawn, length: 12, line: 4_242)
        let call = BlockingOpenCall(fileID: 1, packed: packed)
        #expect(call.kind == .processSpawn)
        #expect(packed >> 32 == 4_242)
        #expect((packed >> 16) & 0xFFFF == 12)
        #expect(BlockingOpenCall.none.summary == nil)
    }

    /// Runs `body` with the detector's records in a table of its own, so these calls on the main thread
    /// never reach the process's table (the open call is always the process's: ``BlockingOpenCall/current()``).
    @MainActor
    private static func recorded<T>(_ body: () throws -> T) rethrows -> T {
        let table = BlockingViolationTable(mode: .record)
        return try BlockingViolationTable.$scoped.withValue(table) { try body() }
    }
}
#endif
