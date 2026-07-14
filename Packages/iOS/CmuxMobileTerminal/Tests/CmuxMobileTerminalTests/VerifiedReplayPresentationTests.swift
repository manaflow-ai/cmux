#if canImport(UIKit)
import CoreGraphics
import Foundation
import IOSurface
import Testing
@testable import CmuxMobileTerminal

@Suite("Verified replay presentation")
struct VerifiedReplayPresentationTests {
    @Test("the retained last-good frame owns immutable pixel bytes")
    func frozenFrameDoesNotAliasRendererIOSurface() throws {
        let source = try makeSurface(fill: 0x11)
        let frozen = try #require(VerifiedReplayFrameCapture.copyCGImage(from: source))

        overwrite(source, with: 0xEE)

        let frozenData = try #require(frozen.dataProvider?.data)
        let frozenBytes = try #require(CFDataGetBytePtr(frozenData))
        #expect(frozenBytes[0] == 0x11)
        #expect(frozenBytes[1] == 0x11)
    }

    @Test("reveal waits for a changed GPU target to reach the presentation tree")
    func presentationFenceRequiresChangedPresentedTarget() {
        let initial = VerifiedReplayRendererSurfaceIdentity(id: 7, seed: 10)
        let completed = VerifiedReplayRendererSurfaceIdentity(id: 8, seed: 11)
        let fence = VerifiedReplayPresentationFence(initialIdentity: initial)

        #expect(!fence.isSatisfied(modelIdentity: initial, presentationIdentity: initial))
        #expect(!fence.isSatisfied(modelIdentity: completed, presentationIdentity: initial))
        #expect(fence.isSatisfied(modelIdentity: completed, presentationIdentity: completed))
    }

    private func makeSurface(fill byte: UInt8) throws -> IOSurface {
        let width = 2
        let height = 2
        let bytesPerRow = width * 4
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: UInt32(0x4247_5241),
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        overwrite(surface, with: byte)
        return surface
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
