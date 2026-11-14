@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// Ghostty's present callback (`ghostty_surface_set_present_callback`) replaced the `setContents:` swizzle on every
/// surface layer (ghostty-integration P23): each frame Ghostty shows reaches the surface's ``TerminalPresents``
/// through the C callback, with its pixel size and reason, and tells the predictive echo engine a frame presented.
@Suite struct TerminalPresentsTests {
    /// A present at 80x60 with the reason content, through the C callback and the bridge as its userdata, is the last
    /// frame at 80x60 with the reason content, counts once and retires a frame in the echo engine.
    @Test func aPresentThroughTheCallbackIsTheLastFrameAndCountsOnce() {
        let (_, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
        let prediction = TerminalEchoPrediction(enabled: false, remote: false)
        let bridge = SurfaceBridge(input: TerminalInputSink(continuation: continuation), prediction: prediction)
        defer { continuation.finish() }
        #expect(bridge.presents.last == nil && bridge.presents.count == 0)

        var raw = ghostty_surface_present_s(width_px: 80, height_px: 60, reason: GHOSTTY_PRESENT_CONTENT, seq: 7,
                                            host_time: 1234)
        withExtendedLifetime(bridge) {
            withUnsafePointer(to: &raw) { ghosttyPresent(Unmanaged.passUnretained(bridge).toOpaque(), $0) }
        }

        #expect(bridge.presents.last == TerminalPresents.Present(widthPixels: 80, heightPixels: 60, reason: .content,
                                                                 sequence: 7, hostTime: 1234))
        #expect(bridge.presents.count == 1)
        #expect(prediction.presentedFrames == 1)
    }

    /// A frame of a new size carries the reason resize; the last frame is the newest one.
    @Test func aResizePresentIsReportedAsResizeAndReplacesTheLastFrame() {
        let presents = TerminalPresents(prediction: nil)
        presents.record(TerminalPresents.Present(ghostty_surface_present_s(
            width_px: 80, height_px: 60, reason: GHOSTTY_PRESENT_CONTENT, seq: 1, host_time: 1)))
        presents.record(TerminalPresents.Present(ghostty_surface_present_s(
            width_px: 160, height_px: 120, reason: GHOSTTY_PRESENT_RESIZE, seq: 0, host_time: 2)))
        #expect(presents.last?.reason == .resize)
        #expect(presents.last?.widthPixels == 160 && presents.last?.heightPixels == 120)
        #expect(presents.count == 2)
    }
}
