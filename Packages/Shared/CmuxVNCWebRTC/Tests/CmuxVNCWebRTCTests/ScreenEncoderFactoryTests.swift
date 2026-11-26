@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// The screen encoder opens H.264 at VideoToolbox's AutoLevel: at the
/// negotiated level 5.2 libwebrtc caps a 3456×2234 display at 68 fps.
struct ScreenEncoderFactoryTests {
    @Test func h264KeepsItsProfileAndLosesTheLevelCap() throws {
        let negotiated = RTCVideoCodecInfo(name: "H264", parameters: [
            "profile-level-id": "640c34", "packetization-mode": "1", "level-asymmetry-allowed": "1",
        ])
        let info = ScreenEncoderFactory.encoderInfo(negotiated)
        let level = try #require(info.parameters["profile-level-id"])
        #expect(level == "640c0a", "Constrained High kept, level 1 (libwebrtc: AutoLevel, no frame rate cap)")
        #expect(RTCH264ProfileLevelId(hexString: level).profile == RTCH264ProfileLevelId(hexString: "640c34").profile)
        #expect(RTCH264ProfileLevelId(hexString: level).level.rawValue == 10)
        #expect(info.parameters["packetization-mode"] == "1")
        #expect(info.parameters["level-asymmetry-allowed"] == "1")
        let baseline = ScreenEncoderFactory.encoderInfo(RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "42e034"]))
        #expect(baseline.parameters["profile-level-id"] == "42e00a")
    }

    @Test func otherCodecsAreAsNegotiated() {
        let vp8 = ScreenEncoderFactory.encoderInfo(RTCVideoCodecInfo(name: "VP8"))
        #expect(vp8.name == "VP8" && vp8.parameters.isEmpty)
        let malformed = ScreenEncoderFactory.encoderInfo(RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "64"]))
        #expect(malformed.parameters["profile-level-id"] == "64")
    }

    #if os(macOS)
    /// VideoToolbox starts the encoder at AutoLevel and encodes at a 16"
    /// MacBook Pro's full size at 120 fps and at 1080p60 (macOS: the Mac
    /// host's encoder; three frames, a fraction of a second).
    @Test(.timeLimit(.minutes(1)), arguments: [(3456, 2234, 120), (1920, 1080, 60)])
    func theEncoderEncodesAtAutoLevel(width: Int, height: Int, fps: Int) async throws {
        let factory = ScreenEncoderFactory()
        let h264 = try #require(factory.supportedCodecs().first { $0.name == "H264" })
        let encoder = try #require(factory.createEncoder(h264))
        let encoded = EncodedCount()
        encoder.setCallback { image, _ in
            encoded.add(image.buffer.count)
            return true
        }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"
        settings.width = UInt16(width)
        settings.height = UInt16(height)
        settings.startBitrate = 12000
        settings.maxBitrate = 24000
        settings.minBitrate = 300
        settings.maxFramerate = UInt32(fps)
        settings.qpMax = 51
        settings.mode = .screensharing
        #expect(encoder.startEncode(with: settings, numberOfCores: 4) == 0)
        defer { _ = encoder.release() }
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &made)
        let pixels = try #require(made)
        for index in 0 ..< 3 {
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                                      timeStampNs: Int64(index) * 1_000_000_000 / Int64(fps))
            let type: RTCFrameType = index == 0 ? .videoFrameKey : .videoFrameDelta
            #expect(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: type.rawValue)]) == 0)
        }
        for _ in 0 ..< 50 where encoded.frames < 3 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(encoded.frames == 3, "VideoToolbox encoded \(encoded.frames) of 3 frames at \(width)x\(height) \(fps) fps")
        #expect(encoded.bytes > 0)
    }
    #endif
}

private final class EncodedCount: @unchecked Sendable {
    // @unchecked: the counts are behind `lock`.
    private let lock = NSLock()
    private var count = 0
    private var total = 0
    func add(_ bytes: Int) { lock.withLock { count += 1; total += bytes } }
    var frames: Int { lock.withLock { count } }
    var bytes: Int { lock.withLock { total } }
}
