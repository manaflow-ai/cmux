import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import CmuxMobileBrowserStream

/// Real H.264 from VideoToolbox, framed as the Mac sends it (Annex-B, SPS and
/// PPS before each IDR), decoded by `BrowserVideoDecoder`.
@Suite struct DecoderTests {
    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var units: [Data] = []
        var shown: [BrowserVideoDecoder.Shown] = []
        var keyframeRequests = 0
    }

    static func encode(frames: Int, width: Int32, height: Int32) throws -> [Data] {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        let session = try #require(status == noErr ? created : nil)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let collected = Collected()
        for n in 0..<frames {
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, nil, &pixels)
            let buffer = try #require(pixels)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + n * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let properties: CFDictionary? = n == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(n), timescale: 30),
                                            duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { _, _, sample in
                guard let sample else { return }
                collected.lock.withLock { collected.units.append(Self.annexB(sample)) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        return collected.lock.withLock { collected.units }
    }

    /// AVCC sample to Annex-B, with the parameter sets in front of a keyframe.
    static func annexB(_ sample: CMSampleBuffer) -> Data {
        var out = Data()
        let start: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer { out.append(contentsOf: start); out.append(pointer, count: size) }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return out }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return out }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {
            let nal = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            out.append(contentsOf: start)
            out.append(bytes + offset + 4, count: nal)
            offset += 4 + nal
        }
        return out
    }

    @Test(.timeLimit(.minutes(1))) func decodesTheMacsAnnexBAndSkipsToAKeyframe() async throws {
        let units = try Self.encode(frames: 6, width: 320, height: 240)
        try #require(units.count == 6)
        #expect(AnnexBAccessUnit(units[0]).isIDR && AnnexBAccessUnit(units[0]).sps != nil)
        let decoder = BrowserVideoDecoder()
        let collected = Collected()
        decoder.shown = { shown in collected.lock.withLock { collected.shown.append(shown) } }
        decoder.requestKeyframe = { collected.lock.withLock { collected.keyframeRequests += 1 } }
        // A P-frame before any keyframe is skipped.
        decoder.submit(frame: 9, accessUnit: units[1], keyframe: false, receivedMicros: 0, ageMicros: nil)
        for (n, unit) in units.enumerated() {
            decoder.submit(frame: UInt32(n), accessUnit: unit, keyframe: n == 0, receivedMicros: 0, ageMicros: 12_000)
        }
        for _ in 0..<200 where collected.lock.withLock({ collected.shown.count }) < 6 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let shown = collected.lock.withLock { collected.shown }
        #expect(shown.map(\.frame) == [0, 1, 2, 3, 4, 5])
        #expect(shown.first?.width == 320 && shown.first?.height == 240)
        #expect(shown.allSatisfy { ($0.latencyMicros ?? 0) >= 12_000 })
    }

    /// The 2026-10-24 freeze class: a decoder whose session died (iOS
    /// invalidates it while the app is in the background) failed every frame,
    /// keyframes included, and asked for a keyframe forever. The next
    /// keyframe now starts a new session.
    @Test(.timeLimit(.minutes(1))) func aDeadSessionIsReplacedAtTheNextKeyframe() async throws {
        let units = try Self.encode(frames: 3, width: 320, height: 240)
        try #require(units.count == 3)
        let decoder = BrowserVideoDecoder()
        let collected = Collected()
        decoder.shown = { shown in collected.lock.withLock { collected.shown.append(shown) } }
        decoder.requestKeyframe = { collected.lock.withLock { collected.keyframeRequests += 1 } }
        decoder.submit(frame: 0, accessUnit: units[0], keyframe: true, receivedMicros: 0, ageMicros: nil)
        for _ in 0..<200 where collected.lock.withLock({ collected.shown.count }) < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(collected.lock.withLock { collected.shown.count } == 1)
        decoder.invalidateSessionForTesting()
        // The P-frame fails on the dead session and asks for a keyframe...
        decoder.submit(frame: 1, accessUnit: units[1], keyframe: false, receivedMicros: 0, ageMicros: nil)
        for _ in 0..<200 where collected.lock.withLock({ collected.keyframeRequests }) < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        // ...and the keyframe that answers shows.
        decoder.submit(frame: 2, accessUnit: units[0], keyframe: true, receivedMicros: 0, ageMicros: nil)
        for _ in 0..<200 where collected.lock.withLock({ collected.shown.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let shown = collected.lock.withLock { collected.shown.map(\.frame) }
        #expect(shown == [0, 2])
        #expect(collected.lock.withLock { collected.keyframeRequests } == 1)
    }
}
