@testable import CmuxNextRemoteView
import CoreMedia
import CoreVideo
import QuartzCore
import Testing

/// Screen Sharing felt slower than macOS Screen Sharing (Leo, 2026-11-16: "let's really speed up
/// this stuff"). Two viewer costs sat on every frame: the decoder asked for full-range NV12 while
/// the Mac host encodes video range, so VideoToolbox converted each frame; and the Metal layer
/// waited for the next refresh on present, with two drawables, so `nextDrawable` could wait on
/// the compositor as well.
@Suite struct RemoteFastPresentTests {
    private func format(fullRange: Bool?) throws -> CMVideoFormatDescription {
        var extensions: [CFString: Any] = [:]
        if let fullRange { extensions[kCMFormatDescriptionExtension_FullRangeVideo] = fullRange }
        var out: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            extensions: extensions as CFDictionary, formatDescriptionOut: &out)
        #expect(status == noErr)
        return try #require(out)
    }

    @Test func aVideoRangeStreamDecodesToVideoRange() throws {
        #expect(RemoteVideoDecoder.outputPixelFormat(for: try format(fullRange: false))
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test func aStreamThatSaysNothingIsVideoRange() throws {
        // H.264's default when the VUI carries no video_full_range_flag.
        #expect(RemoteVideoDecoder.outputPixelFormat(for: try format(fullRange: nil))
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test func aFullRangeStreamStaysFullRange() throws {
        #expect(RemoteVideoDecoder.outputPixelFormat(for: try format(fullRange: true))
            == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    @MainActor @Test func presentDoesNotWaitForTheRefresh() throws {
        let presenter = try #require(MetalFramePresenter())
        let layer = try #require(presenter.layer as? CAMetalLayer)
        #expect(!layer.displaySyncEnabled)
        #expect(layer.maximumDrawableCount == 3)
    }
}
