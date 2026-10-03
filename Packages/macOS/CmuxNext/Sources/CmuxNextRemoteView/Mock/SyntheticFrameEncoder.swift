import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A low-latency VTCompressionSession like the host's (section 5): real time,
/// no frame reordering, an infinite GOP, hardware first. Encodes painted
/// frames and returns Annex-B access units with parameter sets before every
/// keyframe, exactly as the host sends them.
nonisolated final class SyntheticFrameEncoder {
    let codec: RemoteVideoCodec
    let width: Int
    let height: Int
    private let session: VTCompressionSession

    init?(codec: RemoteVideoCodec, width: Int, height: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
        ]
        var created: VTCompressionSession?
        for spec in specs where created == nil {
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard let created else { return nil }
        session = created
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 1_000_000 as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, 8_000_000 as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
        ]
        for (key, value) in properties { VTSessionSetProperty(created, key: key, value: value) }
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// A buffer from the encoder's pool to paint into.
    func makeBuffer() -> CVPixelBuffer? {
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// Encodes one frame; `completion` runs on a VideoToolbox thread with the
    /// Annex-B bytes and whether the frame is a keyframe (nil on failure).
    func encode(
        _ buffer: CVPixelBuffer, index: Int, forceKeyframe: Bool,
        completion: @escaping @Sendable ((data: Data, keyframe: Bool)?) -> Void
    ) {
        let pts = CMTime(value: CMTimeValue(index), timescale: 60)
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let codec = self.codec
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample else { return completion(nil) }
            let keyframe = Self.isKeyframe(sample)
            completion(Self.annexB(sample, keyframe: keyframe, codec: codec).map { ($0, keyframe) })
        }
        if status != noErr { completion(nil) }
    }

    /// Asks VideoToolbox to emit every pending frame now.
    func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// Length-prefixed encoder output to Annex-B, with the parameter sets
    /// (H.264 SPS, PPS; HEVC VPS, SPS, PPS) before a keyframe.
    static func annexB(_ sample: CMSampleBuffer, keyframe: Bool, codec: RemoteVideoCodec) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for set in parameterSets(format, codec: codec) {
                out.append(contentsOf: startCode)
                out.append(contentsOf: set)
            }
        }
        let total = CMBlockBufferGetDataLength(block)
        var raw = [UInt8](repeating: 0, count: total)
        let status = raw.withUnsafeMutableBytes { destination -> OSStatus in
            guard let base = destination.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard status == noErr else { return nil }
        var offset = 0
        while offset + 4 <= total {
            let length = Int(raw[offset]) << 24 | Int(raw[offset + 1]) << 16 | Int(raw[offset + 2]) << 8 | Int(raw[offset + 3])
            offset += 4
            guard length > 0, offset + length <= total else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: raw[offset..<(offset + length)])
            offset += length
        }
        return out
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: RemoteVideoCodec) -> [[UInt8]] {
        var count = 0
        func set(at index: Int) -> [UInt8]? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = switch codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: size))
        }
        // The first call also reports how many sets there are.
        guard let first = set(at: 0) else { return [] }
        return [first] + (1..<max(count, 1)).compactMap(set(at:))
    }
}
