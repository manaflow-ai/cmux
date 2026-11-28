#if os(iOS) && DEBUG
import CmuxDeviceHub
import CmuxScreenKit
import CoreVideo
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// The `cmux.rd/1` viewer's latency probe and its screen link: a test opens a share host it
/// started by the name it gave it, and the probe reads the marker off the pictures the rd
/// decoder hands its layer (`ScreenPresentProbe.enqueued`).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ScreenSharingRdProbeTests {
    private func device(_ id: String, _ name: String) -> HubDevice {
        HubDevice(id: id, name: name, platform: .linux, signingKey: "", macScreenShared: true, online: true)
    }

    @Test func aScreenLinkNamesItsDeviceByIdThenByName() {
        let devices = [device("D-1", "box"), device("d-2", "Studio"), device("box-id", "d-1")]
        #expect(ScreenSharingService.linked("d-1", in: devices)?.id == "D-1")
        #expect(ScreenSharingService.linked("STUDIO", in: devices)?.id == "d-2")
        // An id wins over a device named so.
        #expect(ScreenSharingService.linked("D-1", in: devices)?.name == "box")
        #expect(ScreenSharingService.linked("nope", in: devices) == nil)
    }

    @Test func theMarkerIsParsedFromItsEnvironment() {
        #expect(ScreenSharingLinkRoot.probe("0.05,0")?.cellFraction == 0.05)
        #expect(ScreenSharingLinkRoot.probe("0.05") == nil)
        #expect(ScreenSharingLinkRoot.probe(nil) == nil)
    }

    @Test func theProbeReadsTheMarkerOffAnEnqueuedPicture() throws {
        let probe = ScreenPresentProbe(cellFraction: 32.0 / 640, originY: 0)
        probe.enqueued(try Self.marker(0x1234, guards: [true, false, true, false]))
        #expect(probe.value == 0x1234)
        #expect(probe.frameSize == CGSize(width: 640, height: 360))
        #expect(probe.rendererName == "AVSampleBufferDisplayLayer")
        // A picture without the marker's guards is not read.
        let other = ScreenPresentProbe(cellFraction: 32.0 / 640, originY: 0)
        other.enqueued(try Self.marker(0x1234, guards: [true, true, true, false]))
        #expect(other.value == nil)
    }

    /// A 640 x 360 NV12 (video range) picture with the marker's 20 cells of 32 px at the top.
    private static func marker(_ value: UInt16, guards: [Bool]) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let pixels = try #require(made)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bits = (0 ..< 16).map { value & (1 << $0) != 0 } + guards
        for y in 0 ..< 360 {
            for x in 0 ..< 640 {
                let cell = x / 32
                base[y * stride + x] = y < 32 && cell < 20 && bits[cell] ? 235 : 16
            }
        }
        return pixels
    }
}
#endif
