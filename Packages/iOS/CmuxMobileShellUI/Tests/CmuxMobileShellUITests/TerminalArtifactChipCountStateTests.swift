import Testing
@testable import CmuxMobileShellUI

@Suite("Terminal artifact chip count")
struct TerminalArtifactChipCountStateTests {
    @Test("missing capability and non-positive session totals fall back to the local count")
    func fallbacks() throws {
        var state = TerminalArtifactChipCountState()

        #expect(state.trigger(
            localCount: 4,
            surfaceGeneration: 1,
            supportsSessionCount: false
        ) == .report(.init(count: 4, surfaceGeneration: 1)))

        let nilTotalRequest = try request(from: state.trigger(
            localCount: 5,
            surfaceGeneration: 2,
            supportsSessionCount: true
        ))
        let completion = state.complete(
            nilTotalRequest,
            sessionTotal: nil,
            currentSurfaceGeneration: 2,
            freshestLocalCount: 5
        )
        #expect(completion.outcome == .reported(.init(count: 5, surfaceGeneration: 2)))

        let zeroRequest = try request(from: state.trigger(
            localCount: 6,
            surfaceGeneration: 3,
            supportsSessionCount: true
        ))
        let zeroCompletion = state.complete(
            zeroRequest,
            sessionTotal: 0,
            currentSurfaceGeneration: 3,
            freshestLocalCount: 6
        )
        #expect(zeroCompletion.outcome == .reported(.init(count: 6, surfaceGeneration: 3)))
    }

    @Test("a failed scan holds the last session total instead of regressing to the local count")
    func failedScanHoldsLastSessionTotal() throws {
        var state = TerminalArtifactChipCountState()
        let first = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            first,
            sessionTotal: 12,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 7)))

        let second = try request(from: state.trigger(
            localCount: 1,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            second,
            sessionTotal: nil,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 1
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 7)))
    }

    @Test("session-count triggers report the local count immediately and refine async")
    func sessionTriggersReportProvisionally() throws {
        var state = TerminalArtifactChipCountState()
        guard case .reportAndRequest(let provisional, let request) = state.trigger(
            localCount: 3,
            surfaceGeneration: 5,
            supportsSessionCount: true
        ) else {
            Issue.record("Expected a provisional report plus a session request")
            throw UnexpectedAction()
        }
        #expect(provisional == .init(count: 3, surfaceGeneration: 5))
        #expect(state.complete(
            request,
            sessionTotal: 12,
            currentSurfaceGeneration: 5,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 5)))

        // Once a session total is known, provisional reports hold it instead
        // of regressing to the smaller viewport-only count.
        guard case .reportAndRequest(let upgraded, _) = state.trigger(
            localCount: 1,
            surfaceGeneration: 5,
            supportsSessionCount: true
        ) else {
            Issue.record("Expected a provisional report plus a session request")
            throw UnexpectedAction()
        }
        #expect(upgraded == .init(count: 12, surfaceGeneration: 5))
    }

    @Test("reset forgets the remembered session total")
    func resetForgetsSessionTotal() throws {
        var state = TerminalArtifactChipCountState()
        let seeded = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        _ = state.complete(
            seeded,
            sessionTotal: 12,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        )
        state.reset()

        let fresh = try request(from: state.trigger(
            localCount: 2,
            surfaceGeneration: 8,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            fresh,
            sessionTotal: nil,
            currentSurfaceGeneration: 8,
            freshestLocalCount: 2
        ).outcome == .reported(.init(count: 2, surfaceGeneration: 8)))
    }

    @Test("responses from an old state or surface generation are dropped")
    func staleResponses() throws {
        var resetState = TerminalArtifactChipCountState()
        let resetRequest = try request(from: resetState.trigger(
            localCount: 2,
            surfaceGeneration: 10,
            supportsSessionCount: true
        ))
        resetState.reset()
        #expect(resetState.complete(
            resetRequest,
            sessionTotal: 20,
            currentSurfaceGeneration: 10,
            freshestLocalCount: 2
        ) == .stale)

        var surfaceState = TerminalArtifactChipCountState()
        let surfaceRequest = try request(from: surfaceState.trigger(
            localCount: 3,
            surfaceGeneration: 11,
            supportsSessionCount: true
        ))
        let completion = surfaceState.complete(
            surfaceRequest,
            sessionTotal: 30,
            currentSurfaceGeneration: 12,
            freshestLocalCount: 7
        )
        #expect(completion.outcome == .droppedForSurfaceGenerationMismatch)
        #expect(completion.nextRequest?.surfaceGeneration == 12)
    }

    @Test("surface-generation drops re-arm once with the current generation")
    func droppedResponseRearms() throws {
        var state = TerminalArtifactChipCountState()
        let request = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 11,
            supportsSessionCount: true
        ))

        let dropped = state.complete(
            request,
            sessionTotal: 30,
            currentSurfaceGeneration: 12,
            freshestLocalCount: 8
        )
        let rearmed = try #require(dropped.nextRequest)
        #expect(rearmed.localCount == 8)
        #expect(rearmed.surfaceGeneration == 12)

        let reported = state.complete(
            rearmed,
            sessionTotal: 30,
            currentSurfaceGeneration: 12,
            freshestLocalCount: 8
        )
        #expect(reported.outcome == .reported(.init(count: 30, surfaceGeneration: 12)))
        #expect(reported.nextRequest == nil)
    }

    @Test("surface-generation re-arms stop after the bounded retry count")
    func rearmBound() throws {
        var state = TerminalArtifactChipCountState()
        var request = try request(from: state.trigger(
            localCount: 4,
            surfaceGeneration: 20,
            supportsSessionCount: true
        ))

        for offset in 1...TerminalArtifactChipCountState.maxConsecutiveRearms {
            let completion = state.complete(
                request,
                sessionTotal: 40,
                currentSurfaceGeneration: UInt64(20 + offset),
                freshestLocalCount: 4 + offset
            )
            request = try #require(completion.nextRequest)
        }

        let bounded = state.complete(
            request,
            sessionTotal: 40,
            currentSurfaceGeneration: 100,
            freshestLocalCount: 100
        )
        #expect(bounded.outcome == .droppedForSurfaceGenerationMismatch)
        #expect(bounded.nextRequest == nil)
    }

    @Test("a stale completion leaves the newer in-flight request intact")
    func staleCompletionPreservesNewRequest() throws {
        var state = TerminalArtifactChipCountState()
        let stale = try request(from: state.trigger(
            localCount: 1,
            surfaceGeneration: 30,
            supportsSessionCount: true
        ))
        state.reset()
        let current = try request(from: state.trigger(
            localCount: 2,
            surfaceGeneration: 31,
            supportsSessionCount: true
        ))

        #expect(state.complete(
            stale,
            sessionTotal: 10,
            currentSurfaceGeneration: 31,
            freshestLocalCount: 2
        ) == .stale)
        #expect(state.complete(
            current,
            sessionTotal: 20,
            currentSurfaceGeneration: 31,
            freshestLocalCount: 2
        ).outcome == .reported(.init(count: 20, surfaceGeneration: 31)))
    }

    @Test("one in-flight request coalesces one trailing refresh")
    func coalescesTrailingRefresh() throws {
        var state = TerminalArtifactChipCountState()
        let first = try request(from: state.trigger(
            localCount: 1,
            surfaceGeneration: 20,
            supportsSessionCount: true
        ))
        #expect(state.trigger(
            localCount: 2,
            surfaceGeneration: 21,
            supportsSessionCount: true
        ) == .report(.init(count: 2, surfaceGeneration: 21)))
        #expect(state.trigger(
            localCount: 3,
            surfaceGeneration: 22,
            supportsSessionCount: true
        ) == .report(.init(count: 3, surfaceGeneration: 22)))

        let completion = state.complete(
            first,
            sessionTotal: 10,
            currentSurfaceGeneration: 22,
            freshestLocalCount: 3
        )
        #expect(completion.outcome == .droppedForSurfaceGenerationMismatch)
        #expect(completion.nextRequest?.localCount == 3)
        #expect(completion.nextRequest?.surfaceGeneration == 22)
    }

    private func request(
        from action: TerminalArtifactChipCountState.TriggerAction
    ) throws -> TerminalArtifactChipCountState.Request {
        switch action {
        case .request(let request), .reportAndRequest(_, let request):
            return request
        case .none, .report:
            Issue.record("Expected a session-count request")
            throw UnexpectedAction()
        }
    }

    private struct UnexpectedAction: Error {}
}
