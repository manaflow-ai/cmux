import AppKit
@testable import CmuxTerminalBackendHost
import Testing

@MainActor
@Suite struct BackendOnlyWindowMouseMovedEventsLeaseTests {
    @Test func overlappingLeasesRestoreFalseOnlyAfterLastRelease() {
        let window = NSWindow()
        window.acceptsMouseMovedEvents = false
        let first = BackendOnlyWindowMouseMovedEventsLease(window: window)
        let second = BackendOnlyWindowMouseMovedEventsLease(window: window)

        #expect(window.acceptsMouseMovedEvents)
        first.invalidate()
        #expect(window.acceptsMouseMovedEvents)
        second.invalidate()
        #expect(!window.acceptsMouseMovedEvents)
    }

    @Test func finalReleasePreservesPreexistingTrueValue() {
        let window = NSWindow()
        window.acceptsMouseMovedEvents = true
        let lease = BackendOnlyWindowMouseMovedEventsLease(window: window)

        lease.invalidate()

        #expect(window.acceptsMouseMovedEvents)
    }
}
