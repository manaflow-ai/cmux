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
        ) == .none)
        #expect(state.trigger(
            localCount: 3,
            surfaceGeneration: 22,
            supportsSessionCount: true
        ) == .none)

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
        guard case .request(let request) = action else {
            Issue.record("Expected a session-count request")
            throw UnexpectedAction()
        }
        return request
    }

    private struct UnexpectedAction: Error {}
}
