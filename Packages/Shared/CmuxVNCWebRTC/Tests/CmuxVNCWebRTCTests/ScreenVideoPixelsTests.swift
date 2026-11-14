@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

struct ScreenVideoPixelsTests {
    @Test func hardwareFrameKeepsItsPixelBuffer() throws {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   attributes, &made) == kCVReturnSuccess)
        let pixels = try #require(made)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: 0)
        #expect(ScreenVideoPixels().pixelBuffer(of: frame) === pixels)
    }

    @Test func softwareFramesFollowResolutionChangesWithoutReusingAnOldSizedBuffer() throws {
        let converter = ScreenVideoPixels()
        for (width, height) in [(32, 16), (64, 32), (32, 16)] {
            let source = RTCI420Buffer(width: Int32(width), height: Int32(height))
            let frame = RTCVideoFrame(buffer: source, rotation: ._0, timeStampNs: 0)
            let pixels = try #require(converter.pixelBuffer(of: frame))
            #expect(CVPixelBufferGetWidth(pixels) == width)
            #expect(CVPixelBufferGetHeight(pixels) == height)
            #expect(CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }
}
