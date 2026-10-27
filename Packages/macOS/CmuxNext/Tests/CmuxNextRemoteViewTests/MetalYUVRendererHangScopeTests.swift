@testable import CmuxNextRemoteView
import CmuxNextWakeupsTestSupport
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Testing

/// The remote view's renderer registers the `remote-view.render` lane and draws each frame inside one 250 ms
/// scope, opened after `nextDrawable` returned, so the wait for a drawable is in none; a frame refused before
/// the drawable opens nothing, and the lane is freed with the renderer
/// (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 119).
@Suite(.timeLimit(.minutes(1)), .enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
struct MetalYUVRendererHangScopeTests {
    private static let lane = "remote-view.render"

    private static func layer() -> SharedMetalLayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.maximumDrawableCount = 2
        return SharedMetalLayer(layer)
    }

    private static func frame(_ format: OSType) throws -> RemoteDecodedFrame {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                           kCVPixelBufferMetalCompatibilityKey: true]
        // SAFETY: Core Video writes one +1 buffer to the local `buffer`, live for the call.
        let status = unsafe CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format, attributes as CFDictionary, &buffer)
        #expect(status == kCVReturnSuccess)
        return RemoteDecodedFrame(pixelBuffer: try #require(buffer), frame: 1, tCaptureMicros: 0, decodedAtNanos: 0)
    }

    @Test func eachDrawnFrameIsOneScopeOf250Milliseconds() async throws {
        let hangs = RecordingLaneHangWatch()
        let renderer = try #require(MetalYUVRenderer(layer: Self.layer(), hangs: hangs))
        #expect(hangs.lanes == [Self.lane])
        #expect(MetalYUVRenderer.hangDeadline == .milliseconds(250))

        let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
        _ = mailbox.post(try Self.frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        let shown = await renderer.drawNewest(from: mailbox)
        #expect(shown != nil, "the NV12 frame was not drawn")
        #expect(hangs.entered == [RecordingLaneHangWatch.Scope(lane: Self.lane, deadline: .milliseconds(250))])
        #expect(hangs.open(Self.lane).isEmpty)
    }

    @Test func aFrameRefusedBeforeTheDrawableOpensNoScope() async throws {
        let hangs = RecordingLaneHangWatch()
        let renderer = try #require(MetalYUVRenderer(layer: Self.layer(), hangs: hangs))
        let mailbox = LatestFrameMailbox<RemoteDecodedFrame>()
        // One plane: not NV12, refused before the renderer asks for a drawable.
        _ = mailbox.post(try Self.frame(kCVPixelFormatType_32BGRA))
        #expect(await renderer.drawNewest(from: mailbox) == nil)
        #expect(hangs.entered.isEmpty)
    }

    @Test func theLaneIsFreedWithTheRenderer() throws {
        let hangs = RecordingLaneHangWatch()
        var renderer = MetalYUVRenderer(layer: Self.layer(), hangs: hangs)
        #expect(renderer != nil)
        #expect(hangs.unregistered.isEmpty)
        renderer = nil
        #expect(hangs.unregistered == [Self.lane])
    }
}
