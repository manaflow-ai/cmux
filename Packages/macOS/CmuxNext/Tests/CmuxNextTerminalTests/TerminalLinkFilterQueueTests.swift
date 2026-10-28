import Dispatch
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A filter built with its default schedule runs its file checks on its own named concurrent queue,
/// not a GCD root queue: a check that stalls on a slow volume holds no later check, in its own
/// terminal or another one. Each test goes through ``TerminalLinkFilter`` itself, so a default schedule that went
/// back to a root queue (no name) or to a serial queue (one stall holds the rest) fails here.
struct TerminalLinkFilterQueueTests {
    nonisolated static let label = "com.cmuxterm.next.terminal.link-check"
    static let wait: DispatchTimeInterval = .seconds(5)

    @Test func aCheckRunsOnTheFiltersNamedQueue() {
        let filter = TerminalLinkFilter()
        let answered = Self.answers(filter)
        filter.setCheck { _, _ in Self.onNamedQueue() }
        #expect(!filter.isLink("Sources/a.swift"), "not checked yet: no link until the check answers")
        #expect(answered.wait(timeout: .now() + Self.wait) == .success, "the check answered on the named queue")
        #expect(filter.isLink("Sources/a.swift"))
    }

    @Test func aStalledCheckHoldsNoLaterCheckOfTheSameFilter() {
        let filter = TerminalLinkFilter()
        let answered = Self.answers(filter)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        filter.setCheck { text, _ in
            if text == "/Volumes/asleep/a.txt" {
                release.wait()
                return false
            }
            return Self.onNamedQueue()
        }
        #expect(!filter.isLink("/Volumes/asleep/a.txt"))
        #expect(!filter.isLink("Sources/b.swift"))
        #expect(answered.wait(timeout: .now() + Self.wait) == .success, "the later check ran while the first one stalled")
        #expect(filter.isLink("Sources/b.swift"))
    }

    @Test func aStalledCheckHoldsNoOtherFilter() {
        let stalled = TerminalLinkFilter(), other = TerminalLinkFilter()
        let answered = Self.answers(other)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        stalled.setCheck { _, _ in
            release.wait()
            return false
        }
        other.setCheck { _, _ in Self.onNamedQueue() }
        #expect(!stalled.isLink("/Volumes/asleep/a.txt"))
        #expect(!other.isLink("Sources/c.swift"))
        #expect(answered.wait(timeout: .now() + Self.wait) == .success, "the other terminal's check ran")
        #expect(other.isLink("Sources/c.swift"))
    }

    /// Signals once per changed answer: a check that says "link" changes the cached "no link".
    private static func answers(_ filter: TerminalLinkFilter) -> DispatchSemaphore {
        let answered = DispatchSemaphore(value: 0)
        filter.onChange { answered.signal() }
        return answered
    }

    /// A link only when the check runs on the filter's named queue, so an answer proves where it ran.
    nonisolated private static func onNamedQueue() -> Bool {
        String(cString: __dispatch_queue_get_label(nil)) == label
    }
}
