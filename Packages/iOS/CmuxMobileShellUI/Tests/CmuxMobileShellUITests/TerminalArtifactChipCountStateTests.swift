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
            sessionID: "session-a",
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 7)))

        // Production-shaped failure: the scan explicitly did NOT succeed, so
        // neither the no-session clearing branch nor the success path runs.
        let second = try request(from: state.trigger(
            localCount: 1,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            second,
            sessionTotal: nil,
            sessionID: nil,
            scanSucceeded: false,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 1
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 7)))
    }

    @Test("a successful response with no session clears the held total")
    func successfulNoSessionResponseClearsHeldTotal() throws {
        var state = TerminalArtifactChipCountState()
        let first = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            first,
            sessionTotal: 12,
            sessionID: "session-a",
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 7)))

        // The session moved off this surface: the scan SUCCEEDS but resolves
        // no session. Unlike a transport failure, this proves the binding is
        // gone, so the held 12 must yield to the local count.
        let second = try request(from: state.trigger(
            localCount: 2,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            second,
            sessionTotal: nil,
            sessionID: nil,
            scanSucceeded: true,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 2
        ).outcome == .reported(.init(count: 2, surfaceGeneration: 7)))
    }

    @Test("gallery row total is authoritative over the legacy session total")
    func galleryRowTotalWins() throws {
        var state = TerminalArtifactChipCountState()
        let request = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))

        #expect(state.complete(
            request,
            galleryRowTotal: 5,
            sessionTotal: 12,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 5, surfaceGeneration: 7)))
    }

    @Test("failed scans hold the last authoritative gallery row total")
    func failedScanHoldsLastGalleryRowTotal() throws {
        var state = TerminalArtifactChipCountState()
        let first = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            first,
            galleryRowTotal: 5,
            sessionTotal: 12,
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 5, surfaceGeneration: 7)))

        // A positive gallery total holds across a failed refresh; a held
        // ZERO yielding to local evidence is covered by
        // failedScanDropsHeldZero.
        let second = try request(from: state.trigger(
            localCount: 9,
            surfaceGeneration: 8,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            second,
            galleryRowTotal: nil,
            sessionTotal: nil,
            currentSurfaceGeneration: 8,
            freshestLocalCount: 9
        ).outcome == .reported(.init(count: 5, surfaceGeneration: 8)))
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

    @Test("a failed scan with fresh local evidence drops a held authoritative zero")
    func failedScanDropsHeldZero() throws {
        var state = TerminalArtifactChipCountState()
        let empty = try request(from: state.trigger(
            localCount: 0,
            surfaceGeneration: 5,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            empty,
            galleryRowTotal: 0,
            sessionTotal: 0,
            currentSurfaceGeneration: 5,
            freshestLocalCount: 0
        ).outcome == .reported(.init(count: 0, surfaceGeneration: 5)))

        // Files appear on screen, but the refresh scan fails: the held zero
        // must yield to the local evidence instead of hiding the chip until
        // the transport recovers.
        let failed = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 5,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            failed,
            galleryRowTotal: nil,
            sessionTotal: nil,
            currentSurfaceGeneration: 5,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 3, surfaceGeneration: 5)))

        // The dropped zero stays dropped: later provisional reports show the
        // local count while the transport is down.
        guard case .reportAndRequest(let provisional, _) = state.trigger(
            localCount: 3,
            surfaceGeneration: 5,
            supportsSessionCount: true
        ) else {
            Issue.record("Expected a provisional report plus a session request")
            throw UnexpectedAction()
        }
        #expect(provisional == .init(count: 3, surfaceGeneration: 5))
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

    @Test("reset for a show-missing mode change forgets the authoritative total")
    func showMissingModeResetForgetsAuthoritativeTotal() throws {
        var state = TerminalArtifactChipCountState()
        let seeded = try request(from: state.trigger(
            localCount: 1,
            surfaceGeneration: 10,
            supportsSessionCount: true
        ))
        _ = state.complete(
            seeded,
            galleryRowTotal: 8,
            sessionTotal: 12,
            currentSurfaceGeneration: 10,
            freshestLocalCount: 1
        )

        state.reset()

        guard case .reportAndRequest(let provisional, _) = state.trigger(
            localCount: 2,
            surfaceGeneration: 11,
            supportsSessionCount: true
        ) else {
            Issue.record("Expected reset state to use the local fallback")
            throw UnexpectedAction()
        }
        #expect(provisional == .init(count: 2, surfaceGeneration: 11))
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

    @Test("a new session binding invalidates the held total from the old session")
    func sessionSwitchInvalidatesHeldTotal() throws {
        var state = TerminalArtifactChipCountState()
        let first = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            first,
            sessionTotal: 12,
            sessionID: "session-a",
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        ).outcome == .reported(.init(count: 12, surfaceGeneration: 7)))

        // The terminal binds a new session whose transcript is not indexed
        // yet: the response carries the new session's ID with no total. The
        // old session's 12 must not be shown for it.
        let second = try request(from: state.trigger(
            localCount: 2,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        #expect(state.complete(
            second,
            sessionTotal: nil,
            sessionID: "session-b",
            currentSurfaceGeneration: 7,
            freshestLocalCount: 2
        ).outcome == .reported(.init(count: 2, surfaceGeneration: 7)))
    }

    @Test("a dropped response naming a new session still invalidates the held total")
    func droppedResponseWithNewSessionInvalidates() throws {
        var state = TerminalArtifactChipCountState()
        let first = try request(from: state.trigger(
            localCount: 3,
            surfaceGeneration: 7,
            supportsSessionCount: true
        ))
        _ = state.complete(
            first,
            sessionTotal: 12,
            sessionID: "session-a",
            currentSurfaceGeneration: 7,
            freshestLocalCount: 3
        )

        // Session B starts streaming: its response arrives after the viewport
        // generation advanced, so the count is dropped — but the session
        // identity is generation-independent and must clear A's total.
        let second = try request(from: state.trigger(
            localCount: 2,
            surfaceGeneration: 8,
            supportsSessionCount: true
        ))
        let dropped = state.complete(
            second,
            sessionTotal: nil,
            sessionID: "session-b",
            currentSurfaceGeneration: 9,
            freshestLocalCount: 2
        )
        #expect(dropped.outcome == .droppedForSurfaceGenerationMismatch)

        guard case .provisionalReport(let provisional) = state.trigger(
            localCount: 2,
            surfaceGeneration: 9,
            supportsSessionCount: true
        ) else {
            Issue.record("Expected a provisional report while the re-arm is in flight")
            throw UnexpectedAction()
        }
        #expect(provisional == .init(count: 2, surfaceGeneration: 9))
    }

    @Test("a dropped response's total does not seed provisional reports")
    func droppedResponseDoesNotSeedProvisional() throws {
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
        #expect(dropped.outcome == .droppedForSurfaceGenerationMismatch)

        // The re-armed request is in flight; a fresh viewport trigger must
        // report the local count, not the dropped response's stale total.
        #expect(state.trigger(
            localCount: 8,
            surfaceGeneration: 12,
            supportsSessionCount: true
        ) == .provisionalReport(.init(count: 8, surfaceGeneration: 12)))
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
        ) == .provisionalReport(.init(count: 2, surfaceGeneration: 21)))
        #expect(state.trigger(
            localCount: 3,
            surfaceGeneration: 22,
            supportsSessionCount: true
        ) == .provisionalReport(.init(count: 3, surfaceGeneration: 22)))

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
        case .none, .report, .provisionalReport:
            Issue.record("Expected a session-count request")
            throw UnexpectedAction()
        }
    }

    private struct UnexpectedAction: Error {}
}
