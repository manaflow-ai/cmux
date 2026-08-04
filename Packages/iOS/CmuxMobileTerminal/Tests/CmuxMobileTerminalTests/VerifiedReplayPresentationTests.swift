#if canImport(UIKit)
import CoreGraphics
import Foundation
import IOSurface
import Testing
@testable import CmuxMobileTerminal

@Suite("Verified replay presentation")
struct VerifiedReplayPresentationTests {
    @Test("verified render-grid scrolling waits for the authoritative Mac frame")
    func verifiedReplayUsesRemoteScrollAuthority() {
        #expect(!TerminalScrollPresentationAuthority.verifiedRenderGrid.appliesLocally)
        #expect(TerminalScrollPresentationAuthority.legacyMirror.appliesLocally)
    }

    @Test("a cold surface does not wait for an impossible presented-frame drain")
    func coldSurfaceSkipsPresentedFrameDrain() {
        #expect(!GhosttySurfaceView.requiresVerifiedReplayPresentedDrain(
            hasPresentedContents: false
        ))
        #expect(GhosttySurfaceView.requiresVerifiedReplayPresentedDrain(
            hasPresentedContents: true
        ))
    }

    @Test("the retained last-good frame owns immutable pixel bytes")
    func frozenFrameDoesNotAliasRendererIOSurface() throws {
        let source = try makeSurface(fill: 0x11)
        let frozen = try #require(copyVerifiedReplayCGImage(from: source))

        overwrite(source, with: 0xEE)

        let frozenData = try #require(frozen.dataProvider?.data)
        let frozenBytes = try #require(CFDataGetBytePtr(frozenData))
        #expect(frozenBytes[0] == 0x11)
        #expect(frozenBytes[1] == 0x11)
    }

    @Test("a stale in-flight completion cannot satisfy the replay submission fence")
    func presentationFenceRequiresExactSubmissionToken() {
        let stale = makeIdentity(id: 8, seed: 11)
        let replay = makeIdentity(id: 9, seed: 12)
        let geometry = makeGeometry()
        var fence = VerifiedReplayPresentationFence(
            expectedToken: 42,
            expectedGeometryRevision: 7,
            expectedGeometry: geometry
        )

        let acceptedStale = fence.acknowledge(
            token: 41,
            modelIdentity: stale,
            geometryRevision: 7,
            geometry: geometry
        )
        #expect(!acceptedStale)
        #expect(!fence.isSatisfied(
            modelIdentity: stale,
            presentationIdentity: stale,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
        let acceptedReplay = fence.acknowledge(
            token: 42,
            modelIdentity: replay,
            geometryRevision: 7,
            geometry: geometry
        )
        #expect(acceptedReplay)
    }

    @Test("presentation waits for grid readback and the exact surface allocation")
    func presentationFenceRequiresReadbackAndSurfaceIdentity() {
        let stale = makeIdentity(id: 8, seed: 11)
        let replay = makeIdentity(id: 9, seed: 12)
        let geometry = makeGeometry()
        var fence = VerifiedReplayPresentationFence(
            expectedToken: 42,
            expectedGeometryRevision: 7,
            expectedGeometry: geometry
        )
        let acceptedReplay = fence.acknowledge(
            token: 42,
            modelIdentity: replay,
            geometryRevision: 7,
            geometry: geometry
        )
        #expect(acceptedReplay)

        #expect(!fence.isSatisfied(
            modelIdentity: replay,
            presentationIdentity: stale,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
        #expect(!fence.isSatisfied(
            modelIdentity: replay,
            presentationIdentity: replay,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
        fence.markObservedFrameReady()
        #expect(fence.isSatisfied(
            modelIdentity: replay,
            presentationIdentity: replay,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
    }

    @Test("presentation accepts the tokened IOSurface after its content seed advances")
    func presentationFenceTracksAllocationAcrossSeedAdvance() {
        let assigned = makeIdentity(id: 9, seed: 12)
        let presented = makeIdentity(id: 9, seed: 13)
        let divergent = makeIdentity(id: 9, seed: 14)
        let otherAllocation = makeIdentity(id: 10, seed: 13)
        let geometry = makeGeometry()
        var fence = VerifiedReplayPresentationFence(
            expectedToken: 42,
            expectedGeometryRevision: 7,
            expectedGeometry: geometry
        )

        let acceptedAssigned = fence.acknowledge(
            token: 42,
            modelIdentity: assigned,
            geometryRevision: 7,
            geometry: geometry
        )
        #expect(acceptedAssigned)
        fence.markObservedFrameReady()

        #expect(fence.isSatisfied(
            modelIdentity: presented,
            presentationIdentity: presented,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
        #expect(fence.isSatisfied(
            modelIdentity: presented,
            presentationIdentity: divergent,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
        #expect(!fence.isSatisfied(
            modelIdentity: otherAllocation,
            presentationIdentity: otherAllocation,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
        #expect(!fence.isSatisfied(
            modelIdentity: presented,
            presentationIdentity: otherAllocation,
            geometryRevision: 7,
            modelGeometry: geometry,
            presentationGeometry: geometry
        ))
    }

    @Test("presentation rejects a replay when keyboard relayout changes geometry")
    func presentationFenceRejectsGeometryChanges() {
        let identity = makeIdentity(id: 9, seed: 12)
        let initial = makeGeometry()
        let relaid = makeGeometry(rendererFrame: CGRect(x: 0, y: 0, width: 390, height: 500))
        var fence = VerifiedReplayPresentationFence(
            expectedToken: 42,
            expectedGeometryRevision: 7,
            expectedGeometry: initial
        )

        let acceptedReplay = fence.acknowledge(
            token: 42,
            modelIdentity: identity,
            geometryRevision: 7,
            geometry: initial
        )
        #expect(acceptedReplay)
        fence.markObservedFrameReady()

        #expect(!fence.isSatisfied(
            modelIdentity: identity,
            presentationIdentity: identity,
            geometryRevision: 8,
            modelGeometry: initial,
            presentationGeometry: initial
        ))
        #expect(!fence.isSatisfied(
            modelIdentity: identity,
            presentationIdentity: identity,
            geometryRevision: 7,
            modelGeometry: relaid,
            presentationGeometry: relaid
        ))

        let wrongPixelExtent = makeIdentity(
            id: 9,
            seed: 12,
            pixelWidth: 1_170,
            pixelHeight: 1_500
        )
        #expect(!fence.isSatisfied(
            modelIdentity: wrongPixelExtent,
            presentationIdentity: wrongPixelExtent,
            geometryRevision: 7,
            modelGeometry: initial,
            presentationGeometry: initial
        ))
        #expect(!fence.isSatisfied(
            modelIdentity: identity,
            presentationIdentity: identity,
            geometryRevision: 7,
            modelGeometry: initial,
            presentationGeometry: relaid
        ))
    }

}

private extension VerifiedReplayPresentationTests {
    private func makeSurface(fill byte: UInt8) throws -> IOSurface {
        let width = 2
        let height = 2
        let bytesPerRow = width * 4
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: UInt32(0x4247_5241)
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        overwrite(surface, with: byte)
        return surface
    }

    private func makeGeometry(
        rendererFrame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 700)
    ) -> VerifiedReplayPresentationGeometry {
        VerifiedReplayPresentationGeometry(
            rendererFrame: rendererFrame,
            rendererBounds: CGRect(origin: .zero, size: rendererFrame.size),
            rendererPosition: CGPoint(x: rendererFrame.midX, y: rendererFrame.midY),
            rendererAnchorPoint: CGPoint(x: 0.5, y: 0.5),
            rendererContentsScale: 3,
            rendererTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            hostBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            hostPosition: CGPoint(x: 195, y: 422),
            hostAnchorPoint: CGPoint(x: 0.5, y: 0.5),
            hostTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            viewportRect: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
    }

    private func makeIdentity(
        id: UInt32,
        seed: UInt32,
        pixelWidth: Int = 1_170,
        pixelHeight: Int = 2_100
    ) -> VerifiedReplayRendererSurfaceIdentity {
        VerifiedReplayRendererSurfaceIdentity(
            id: id,
            seed: seed,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func overwrite(_ surface: IOSurface, with byte: UInt8) {
        #expect(IOSurfaceLock(surface, [], nil) == 0)
        memset(
            IOSurfaceGetBaseAddress(surface),
            Int32(byte),
            IOSurfaceGetBytesPerRow(surface) * IOSurfaceGetHeight(surface)
        )
        #expect(IOSurfaceUnlock(surface, [], nil) == 0)
    }
}
#endif
