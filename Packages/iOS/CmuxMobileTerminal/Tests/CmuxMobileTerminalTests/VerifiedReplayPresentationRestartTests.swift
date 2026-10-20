#if canImport(UIKit)
import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

@Suite("Verified replay presentation restart")
struct VerifiedReplayPresentationRestartTests {
    @Test("geometry transition replaces the token and rejects the stale callback")
    func presentationFenceRestartsForNewestGeometry() {
        let initial = makeGeometry()
        let transitioned = makeTransitionedGeometry()
        let identity = makeTransitionedIdentity()
        var fence = makeFence(geometry: initial)
        fence.markObservedFrameReady()

        fence.restart(
            expectedToken: 43,
            expectedGeometryRevision: 8,
            expectedGeometry: transitioned
        )
        let acceptedStale = fence.acknowledge(
            token: 42,
            modelIdentity: identity,
            geometryRevision: 7,
            geometry: initial
        )
        let acceptedReplacement = fence.acknowledge(
            token: 43,
            modelIdentity: identity,
            geometryRevision: 8,
            geometry: transitioned
        )

        #expect(!acceptedStale)
        #expect(acceptedReplacement)
        #expect(!isSatisfied(fence, identity: identity, geometry: transitioned))
        fence.markObservedFrameReady()
        #expect(isSatisfied(fence, identity: identity, geometry: transitioned))
    }

    @Test("geometry transition keeps a token-only drain ready")
    func presentationFenceRestartsTokenOnlyDrainReady() {
        let transitioned = makeTransitionedGeometry()
        let identity = makeTransitionedIdentity()
        var fence = makeFence(geometry: makeGeometry())

        fence.restart(
            expectedToken: 43,
            expectedGeometryRevision: 8,
            expectedGeometry: transitioned,
            observedFrameReady: true
        )
        let accepted = fence.acknowledge(
            token: 43,
            modelIdentity: identity,
            geometryRevision: 8,
            geometry: transitioned
        )

        #expect(accepted)
        #expect(isSatisfied(fence, identity: identity, geometry: transitioned))
    }
}

private extension VerifiedReplayPresentationRestartTests {
    func makeFence(
        geometry: VerifiedReplayPresentationGeometry
    ) -> VerifiedReplayPresentationFence {
        VerifiedReplayPresentationFence(
            expectedToken: 42,
            expectedGeometryRevision: 7,
            expectedGeometry: geometry
        )
    }

    func makeTransitionedGeometry() -> VerifiedReplayPresentationGeometry {
        makeGeometry(rendererFrame: CGRect(x: 0, y: 0, width: 390, height: 500))
    }

    func makeGeometry(
        rendererFrame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 700)
    ) -> VerifiedReplayPresentationGeometry {
        VerifiedReplayPresentationGeometry(
            rendererFrame: rendererFrame,
            rendererBounds: CGRect(origin: .zero, size: rendererFrame.size),
            rendererPosition: CGPoint(x: rendererFrame.midX, y: rendererFrame.midY),
            rendererAnchorPoint: CGPoint(x: 0.5, y: 0.5),
            rendererContentsScale: 3,
            rendererTransform: identityTransform,
            hostBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            hostPosition: CGPoint(x: 195, y: 422),
            hostAnchorPoint: CGPoint(x: 0.5, y: 0.5),
            hostTransform: identityTransform,
            viewportRect: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
    }

    var identityTransform: [CGFloat] {
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }

    func makeTransitionedIdentity() -> VerifiedReplayRendererSurfaceIdentity {
        VerifiedReplayRendererSurfaceIdentity(
            id: 10,
            seed: 13,
            pixelWidth: 1_170,
            pixelHeight: 1_500
        )
    }

    func isSatisfied(
        _ fence: VerifiedReplayPresentationFence,
        identity: VerifiedReplayRendererSurfaceIdentity,
        geometry: VerifiedReplayPresentationGeometry
    ) -> Bool {
        fence.isSatisfied(
            modelIdentity: identity,
            presentationIdentity: identity,
            geometryRevision: 8,
            modelGeometry: geometry,
            presentationGeometry: geometry
        )
    }
}
#endif
