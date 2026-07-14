import Testing
@testable import CmuxMobileShellUI

@Suite("Terminal artifact chip count")
struct TerminalArtifactChipCountStateTests {
    @Test("missing capability and missing session total fall back to the local count")
    func fallbacks() throws {
        var state = TerminalArtifactChipCountState()

        #expect(state.trigger(
            localCount: 4,
            surfaceGeneration: 1,
            supportsSessionCount: false
        ) == .report(.init(count: 4, surfaceGeneration: 1)))

        let request = try request(from: state.trigger(
            localCount: 5,
            surfaceGeneration: 2,
            supportsSessionCount: true
        ))
        let completion = state.complete(
            request,
            sessionTotal: nil,
            currentSurfaceGeneration: 2
        )
        #expect(completion.report == .init(count: 5, surfaceGeneration: 2))
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
            currentSurfaceGeneration: 10
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
            currentSurfaceGeneration: 12
        )
        #expect(completion.report == nil)
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
            currentSurfaceGeneration: 22
        )
        #expect(completion.report == nil)
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
