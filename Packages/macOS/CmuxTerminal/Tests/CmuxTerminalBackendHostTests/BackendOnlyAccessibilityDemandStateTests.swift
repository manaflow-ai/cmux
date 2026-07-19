import CmuxTerminalBackend
import Foundation
import Testing
@testable import CmuxTerminalBackendHost

@Suite("Backend-only accessibility demand state")
struct BackendOnlyAccessibilityDemandStateTests {
    private let presentationID = PresentationID(
        rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    )
    private let firstRequestID = UUID(
        uuidString: "40000000-0000-0000-0000-000000000001"
    )!
    private let secondRequestID = UUID(
        uuidString: "40000000-0000-0000-0000-000000000002"
    )!

    @Test("zero to one acquires once and one to zero releases the exact generation")
    func falseTrueFalse() throws {
        var state = BackendOnlyAccessibilityDemandState()
        state.attach(presentationID: presentationID, generation: 7)
        #expect(state.beginNextOperation(requestID: firstRequestID) == nil)

        state.addExplicitObserver()
        let acquire = try #require(state.beginNextOperation(requestID: firstRequestID))
        #expect(acquire == .acquire(
            requestID: firstRequestID,
            presentationID: presentationID,
            expectedGeneration: 7,
            expectedDemandGeneration: nil
        ))
        state.completeAcquire(acquire, demandGeneration: 11)
        #expect(state.isDemandAdmitted)

        state.removeExplicitObserver()
        #expect(!state.isDemandAdmitted)
        let release = try #require(state.beginNextOperation(requestID: secondRequestID))
        #expect(release == .release(
            presentationID: presentationID,
            expectedGeneration: 7,
            demandGeneration: 11
        ))
        state.completeRelease(release, released: true)
        #expect(state.beginNextOperation(requestID: secondRequestID) == nil)
    }

    @Test("explicit and stream observers share one presentation lease")
    func multipleObserversReferenceCountOneLease() throws {
        var state = BackendOnlyAccessibilityDemandState()
        let streamID = UUID()
        state.attach(presentationID: presentationID, generation: 7)
        state.addExplicitObserver()
        state.addStreamObserver(streamID)
        let acquire = try #require(state.beginNextOperation(requestID: firstRequestID))
        state.completeAcquire(acquire, demandGeneration: 11)

        state.removeExplicitObserver()
        #expect(state.observerCount == 1)
        #expect(state.isDemandAdmitted)
        #expect(state.beginNextOperation(requestID: secondRequestID) == nil)

        state.removeStreamObserver(streamID)
        #expect(state.observerCount == 0)
        #expect(!state.isDemandAdmitted)
        #expect(state.beginNextOperation(requestID: secondRequestID) == .release(
            presentationID: presentationID,
            expectedGeneration: 7,
            demandGeneration: 11
        ))
    }

    @Test("disable and re-enable during acquire admits the single replay-safe request")
    func acquireInFlightDisableReenable() throws {
        var state = BackendOnlyAccessibilityDemandState()
        state.attach(presentationID: presentationID, generation: 7)
        state.addExplicitObserver()
        let acquire = try #require(state.beginNextOperation(requestID: firstRequestID))

        state.removeExplicitObserver()
        state.addExplicitObserver()
        state.completeAcquire(acquire, demandGeneration: 11)

        #expect(state.isDemandAdmitted)
        #expect(state.beginNextOperation(requestID: secondRequestID) == nil)
    }

    @Test("ambiguous acquire retry reuses request identity and expectation")
    func ambiguousAcquireRetriesExactly() throws {
        var state = BackendOnlyAccessibilityDemandState()
        state.attach(presentationID: presentationID, generation: 7)
        state.addExplicitObserver()
        let first = try #require(state.beginNextOperation(requestID: firstRequestID))

        state.fail(first)
        let retry = try #require(state.beginNextOperation(requestID: secondRequestID))

        #expect(retry == first)
    }

    @Test("re-enable waits for an in-flight release before acquiring again")
    func releaseInFlightReenableIsSerialized() throws {
        var state = BackendOnlyAccessibilityDemandState()
        state.attach(presentationID: presentationID, generation: 7)
        state.addExplicitObserver()
        let firstAcquire = try #require(
            state.beginNextOperation(requestID: firstRequestID)
        )
        state.completeAcquire(firstAcquire, demandGeneration: 11)
        state.removeExplicitObserver()
        let release = try #require(
            state.beginNextOperation(requestID: secondRequestID)
        )

        state.addExplicitObserver()
        #expect(!state.isDemandAdmitted)
        #expect(state.beginNextOperation(requestID: UUID()) == nil)
        state.completeRelease(release, released: true)
        let reacquire = try #require(state.beginNextOperation(requestID: secondRequestID))
        #expect(reacquire == .acquire(
            requestID: secondRequestID,
            presentationID: presentationID,
            expectedGeneration: 7,
            expectedDemandGeneration: nil
        ))
        state.completeAcquire(reacquire, demandGeneration: 12)
        #expect(state.isDemandAdmitted)
    }

    @Test("stale release completion cannot erase a later admitted generation")
    func staleReleaseDoesNotEraseLaterAcquire() throws {
        var state = BackendOnlyAccessibilityDemandState()
        state.attach(presentationID: presentationID, generation: 7)
        state.addExplicitObserver()
        let firstAcquire = try #require(
            state.beginNextOperation(requestID: firstRequestID)
        )
        state.completeAcquire(firstAcquire, demandGeneration: 11)

        let replacement = BackendOnlyAccessibilityDemandState.Operation.acquire(
            requestID: secondRequestID,
            presentationID: presentationID,
            expectedGeneration: 7,
            expectedDemandGeneration: 11
        )
        state.completeAcquire(replacement, demandGeneration: 12)
        state.completeRelease(
            .release(
                presentationID: presentationID,
                expectedGeneration: 7,
                demandGeneration: 11
            ),
            released: false
        )

        #expect(state.isDemandAdmitted)
        #expect(state.admittedDemandGeneration == 12)
    }

    @Test("detach disables locally and releases the exact daemon generation")
    func detachReleasesDemand() throws {
        var state = BackendOnlyAccessibilityDemandState()
        state.attach(presentationID: presentationID, generation: 7)
        state.addExplicitObserver()
        let acquire = try #require(state.beginNextOperation(requestID: firstRequestID))
        state.completeAcquire(acquire, demandGeneration: 11)

        state.detach(presentationID: presentationID, generation: 7)

        #expect(!state.isDemandAdmitted)
        #expect(state.beginNextOperation(requestID: secondRequestID) == .release(
            presentationID: presentationID,
            expectedGeneration: 7,
            demandGeneration: 11
        ))
    }
}
