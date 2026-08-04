import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact text bottom pin")
struct ChatArtifactTextBottomPinStateMachineTests {
    @Test("End engages a durable bottom pin with one initial animation")
    func endEngagesBottomPin() {
        var pin = ChatArtifactTextBottomPinStateMachine()
        let boundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 149_188
        )

        #expect(
            pin.engage(target: .end, boundary: boundary)
                == .scrollToBottom(boundary: boundary, animated: true)
        )
        #expect(pin.isPinned)
        #expect(pin.target == .end)
        #expect(pin.phase == .initialAnimation)
    }

    @Test("a pinned view re-pins non-animated across late layout growth")
    func repinsAcrossLayoutGrowth() {
        var pin = ChatArtifactTextBottomPinStateMachine()
        let earlyBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 149_188
        )
        let refinedBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 168_000
        )

        _ = pin.engage(target: .end, boundary: earlyBoundary)
        #expect(
            pin.initialAnimationSettled(at: earlyBoundary)
                == .scrollToBottom(boundary: earlyBoundary, animated: false)
        )
        pin.didApplyPin(at: earlyBoundary)

        #expect(
            pin.layoutChanged(to: refinedBoundary)
                == .scrollToBottom(boundary: refinedBoundary, animated: false)
        )
        pin.didApplyPin(at: refinedBoundary)
        #expect(pin.visibleBoundary == refinedBoundary)
    }

    @Test("user interaction exits the pin and later layout cannot re-engage it")
    func userInteractionExitsPin() {
        var pin = ChatArtifactTextBottomPinStateMachine()
        let boundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 168_000
        )

        _ = pin.engage(target: .end, boundary: boundary)
        _ = pin.initialAnimationSettled(at: boundary)
        pin.didApplyPin(at: boundary)
        pin.userInteracted()

        #expect(!pin.isPinned)
        #expect(pin.layoutChanged(to: boundary) == .none)
        #expect(pin.visibleBoundary == nil)
    }

    @Test("streaming follow-tail finishes with the visible boundary at storage end")
    func terminalStateShowsStorageEnd() {
        var pin = ChatArtifactTextBottomPinStateMachine()
        let partialBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 120_000,
            contentOffsetY: 112_000
        )
        let finalBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 168_000
        )

        _ = pin.engage(target: .latest, boundary: partialBoundary)
        _ = pin.initialAnimationSettled(at: partialBoundary)
        pin.didApplyPin(at: partialBoundary)

        #expect(
            pin.appendsFlushed(at: finalBoundary)
                == .scrollToBottom(boundary: finalBoundary, animated: false)
        )
        pin.didApplyPin(at: finalBoundary)
        #expect(
            pin.reachedEOF(at: finalBoundary)
                == .scrollToBottom(boundary: finalBoundary, animated: false)
        )
        pin.didApplyPin(at: finalBoundary)

        #expect(pin.target == .end)
        #expect(pin.phase == .following)
        #expect(pin.visibleBoundary?.storageEnd == finalBoundary.storageEnd)
    }

    @Test("EOF during the initial animation is retained for the terminal settle")
    func eofDuringInitialAnimationIsRetained() {
        var pin = ChatArtifactTextBottomPinStateMachine()
        let partialBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 120_000,
            contentOffsetY: 112_000
        )
        let finalBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 168_000
        )

        _ = pin.engage(target: .latest, boundary: partialBoundary)
        let didMarkEOF = pin.markReachedEOF()
        #expect(didMarkEOF)
        #expect(pin.target == .end)
        #expect(
            pin.initialAnimationSettled(at: finalBoundary)
                == .scrollToBottom(boundary: finalBoundary, animated: false)
        )
        pin.didApplyPin(at: finalBoundary)

        #expect(pin.visibleBoundary == finalBoundary)
    }

    @Test("EOF plus the final deferred append leaves the pinned document end visible")
    func finalDeferredAppendLeavesDocumentEndVisible() {
        var appendPolicy = ChatArtifactTextAppendPolicy()
        var pin = ChatArtifactTextBottomPinStateMachine()
        let preFlushBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 171_817,
            contentOffsetY: 165_817
        )
        let finalBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 168_000
        )

        _ = pin.engage(target: .latest, boundary: preFlushBoundary)
        appendPolicy.beginProgrammaticAnimation()
        // Appends apply immediately even while the pin's own scroll animates,
        // so a missed end-of-animation callback can no longer truncate the
        // storage below the file end.
        #expect(appendPolicy.enqueue(chunkCount: 1) == 1)
        let didReachEOF = pin.markReachedEOF()
        #expect(didReachEOF)

        #expect(appendPolicy.endProgrammaticAnimation() == 0)
        #expect(
            pin.appendsFlushed(at: finalBoundary)
                == .scrollToBottom(boundary: finalBoundary, animated: true)
        )
        #expect(
            pin.initialAnimationSettled(at: preFlushBoundary)
                == .scrollToBottom(boundary: finalBoundary, animated: false)
        )
        pin.didApplyPin(at: finalBoundary)

        #expect(!appendPolicy.isDeferring)
        #expect(pin.target == .end)
        #expect(pin.visibleBoundary == finalBoundary)
    }

    @Test("cold-open End re-arms across immediate appends before concluding at the visible end")
    func coldOpenEndRearmsAcrossImmediateAppends() {
        var appendPolicy = ChatArtifactTextAppendPolicy()
        var pin = ChatArtifactTextBottomPinStateMachine()
        let lineOneBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 1_024,
            contentOffsetY: 0
        )
        let streamedBoundary = ChatArtifactTextBottomBoundary(
            storageEnd: 174_000,
            contentOffsetY: 168_000
        )

        #expect(
            pin.engage(target: .latest, boundary: lineOneBoundary)
                == .scrollToBottom(boundary: lineOneBoundary, animated: true)
        )
        appendPolicy.beginProgrammaticAnimation()

        // Commit 62f57bab4a deliberately applies these chunks immediately.
        #expect(appendPolicy.enqueue(chunkCount: 3) == 3)
        #expect(
            pin.appendsFlushed(at: streamedBoundary)
                == .scrollToBottom(boundary: streamedBoundary, animated: true)
        )
        #expect(pin.phase == .initialAnimation)

        var convergence = ChatArtifactTextJumpConvergence(
            initialTargetOffset: streamedBoundary.contentOffsetY
        )
        #expect(
            convergence.decision(
                observedOffset: lineOneBoundary.contentOffsetY,
                targetOffset: streamedBoundary.contentOffsetY
            ) == .retarget(offset: streamedBoundary.contentOffsetY)
        )
        #expect(pin.phase == .initialAnimation)

        // A settle callback cannot conclude the pin until the requested bottom
        // boundary is genuinely visible.
        #expect(
            pin.initialAnimationSettled(
                at: streamedBoundary,
                isBoundaryVisible: false
            ) == .scrollToBottom(boundary: streamedBoundary, animated: false)
        )
        #expect(pin.phase == .initialAnimation)
        pin.didApplyPin(at: streamedBoundary)

        #expect(appendPolicy.endProgrammaticAnimation() == 0)
        #expect(pin.phase == .following)
        #expect(pin.visibleBoundary == streamedBoundary)
    }
}
