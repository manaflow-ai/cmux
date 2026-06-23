import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("Terminal render flight state")
struct TerminalRenderFlightStateTests {
    @Test("coalesces while a render is in flight")
    func coalescesWhileInFlight() {
        var state = TerminalRenderFlightState()

        #expect(state.request(now: 1, staleTimeout: 3) == .enqueue(generation: 1, replacedStale: false))
        #expect(state.request(now: 2, staleTimeout: 3) == .coalesced)

        #expect(state.complete(generation: 1) == .enqueueCoalesced)
        #expect(state.request(now: 2.1, staleTimeout: 3) == .enqueue(generation: 2, replacedStale: false))
    }

    @Test("reopens the latch when an in-flight render becomes stale")
    func replacesStaleRender() {
        var state = TerminalRenderFlightState()

        #expect(state.request(now: 10, staleTimeout: 3) == .enqueue(generation: 1, replacedStale: false))
        #expect(state.request(now: 14, staleTimeout: 3) == .enqueue(generation: 2, replacedStale: true))

        #expect(state.complete(generation: 1) == .ignoredStaleCompletion)
        #expect(state.complete(generation: 2) == .idle)
    }

    @Test("reset invalidates late completions")
    func resetInvalidatesLateCompletion() {
        var state = TerminalRenderFlightState()

        #expect(state.request(now: 1, staleTimeout: 3) == .enqueue(generation: 1, replacedStale: false))
        state.reset()

        #expect(state.complete(generation: 1) == .ignoredStaleCompletion)
        #expect(state.request(now: 2, staleTimeout: 3) == .enqueue(generation: 3, replacedStale: false))
    }
}
