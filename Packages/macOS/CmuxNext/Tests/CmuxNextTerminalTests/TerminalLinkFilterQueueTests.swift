import Dispatch
@testable import CmuxNextTerminal
import Foundation
import Testing

/// The link filter's file checks run on the filter's own named serial queue (p02-threads-120), not a GCD root
/// queue: a check stalled on a slow volume holds only that terminal's later checks, never another surface's.
struct TerminalLinkFilterQueueTests {
    @Test func checksRunOnTheFiltersNamedQueue() async {
        let schedule = TerminalLinkFilter.ownQueue()
        let label = await Self.label(on: schedule)
        #expect(label == "com.cmuxterm.next.terminal.link-check")
    }

    @Test func aStalledCheckHoldsOnlyItsOwnFilter() async {
        let stalled = TerminalLinkFilter.ownQueue(), other = TerminalLinkFilter.ownQueue()
        let release = DispatchSemaphore(value: 0)
        stalled { release.wait() }
        defer { release.signal() }
        // The other filter's check still runs while the first one's queue is held.
        #expect(await Self.label(on: other) == "com.cmuxterm.next.terminal.link-check")
    }

    private static func label(on schedule: TerminalLinkFilter.Schedule) async -> String {
        await withCheckedContinuation { continuation in
            schedule { continuation.resume(returning: String(cString: __dispatch_queue_get_label(nil))) }
        }
    }
}
