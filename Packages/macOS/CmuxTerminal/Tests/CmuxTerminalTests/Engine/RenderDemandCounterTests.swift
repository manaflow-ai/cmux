import CmuxTerminalCore
import Testing

@testable import CmuxTerminal

@Suite("Render demand counter")
struct RenderDemandCounterTests {
    @Test func startsInactive() {
        let counter = RenderDemandCounter()
        #expect(!counter.isActive)
    }

    @Test func retainActivatesAndReleaseDeactivates() {
        let counter = RenderDemandCounter()
        let retention = counter.retain()
        #expect(counter.isActive)
        retention.release()
        #expect(!counter.isActive)
    }

    @Test func staysActiveWhileAnyRetentionIsOutstanding() {
        let counter = RenderDemandCounter()
        let first = counter.retain()
        let second = counter.retain()
        first.release()
        #expect(counter.isActive)
        second.release()
        #expect(!counter.isActive)
    }

    @Test func releaseIsIdempotentPerRetention() {
        let counter = RenderDemandCounter()
        let first = counter.retain()
        let second = counter.retain()
        first.release()
        first.release()
        first.release()
        // The legacy closure decremented on every call; a retention releases
        // exactly once, so the second retention must still hold demand.
        #expect(counter.isActive)
        second.release()
        #expect(!counter.isActive)
    }

    @Test func countNeverGoesNegative() {
        let counter = RenderDemandCounter()
        counter.retain().release()
        counter.retain().release()
        // A fresh retain after balanced churn must activate again (a negative
        // count would require two retains to recover, like the legacy
        // max(0, count - 1) guard protects against).
        let retention = counter.retain()
        #expect(counter.isActive)
        retention.release()
        #expect(!counter.isActive)
    }
}
