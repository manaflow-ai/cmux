import CmuxBrowserStream
import CoreMedia
import Foundation
import VideoToolbox

/// H.264 for screen content with VideoToolbox (c2-browser-stream.md 1, 3):
/// hardware encoder, low-latency rate control, no frame reordering,
/// keyframes only on request (plus a 10 s safety interval), Annex-B output
/// with SPS and PPS in front of every keyframe.
public actor VideoToolboxH264Encoder: BrowserFrameEncoder {
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var bitrate = 0
    private var fps = 0

    public init() {}

    /// Ends the hardware session; the next `encode` makes a new one.
    public func close() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    public func encode(_ frame: BrowserCapturedFrame, bitrate: Int, maxFPS: Int, forceKeyframe: Bool) async throws -> BrowserEncodedFrame? {
        var force = forceKeyframe
        if session == nil || frame.pixelWidth != width || frame.pixelHeight != height {
            try makeSession(width: frame.pixelWidth, height: frame.pixelHeight, bitrate: bitrate, fps: maxFPS)
            force = true
        } else if bitrate != self.bitrate || maxFPS != fps {
            applyRate(bitrate: bitrate, fps: maxFPS)
        }
        guard let session else { return nil }
        let pts = CMTime(value: CMTimeValue(frame.captureMicros), timescale: 1_000_000)
        let properties: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pixelBuffer = frame.pixelBuffer
        let capture = frame.captureMicros
        let size = (frame.pixelWidth, frame.pixelHeight)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserEncodedFrame?, any Error>) in
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                         duration: .invalid, frameProperties: properties, infoFlagsOut: nil) {
                status, _, sample in
                guard status == noErr else {
                    continuation.resume(throwing: BrowserPageError.failed("encode status \(status)"))
                    return
                }
                guard let sample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(with: Result { try Self.frame(from: sample, capture: capture, size: size) })
            }
            if status != noErr {
                continuation.resume(throwing: BrowserPageError.failed("encode submit status \(status)"))
            }
        }
    }

    private func makeSession(width: Int, height: Int, bitrate: Int, fps: Int) throws {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw BrowserPageError.failed("VTCompressionSessionCreate \(status)") }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 10 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        self.width = width
        self.height = height
        applyRate(bitrate: bitrate, fps: fps)
    }

    private func applyRate(bitrate: Int, fps: Int) {
        guard let session else { return }
        self.bitrate = bitrate
        self.fps = fps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: max(1, fps) as CFNumber)
        // At most 1.5x the target in any one second, so a keyframe cannot flood the path.
        let limits = [bitrate * 3 / 16, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    private nonisolated static func frame(from sample: CMSampleBuffer, capture: UInt64, size: (Int, Int)) throws -> BrowserEncodedFrame {
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw BrowserPageError.failed("no data buffer") }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(buffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else {
            throw BrowserPageError.failed("no data pointer")
        }
        let avcc = Data(bytes: pointer, count: length)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        var parameterSets: [Data] = []
        if !notSync, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0..<2 {
                var setPointer: UnsafePointer<UInt8>?
                var setLength = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                      parameterSetPointerOut: &setPointer,
                                                                      parameterSetSizeOut: &setLength,
                                                                      parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr,
                   let setPointer {
                    parameterSets.append(Data(bytes: setPointer, count: setLength))
                }
            }
        }
        let unit = try H264AccessUnit(lengthPrefixed: avcc, parameterSets: parameterSets)
        return BrowserEncodedFrame(accessUnit: unit.annexB, isKeyframe: !notSync, captureMicros: capture,
                                   pixelWidth: size.0, pixelHeight: size.1)
    }
}
