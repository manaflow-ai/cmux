import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// H.264 of a simulator's own framebuffer (its IOSurface, never the screen),
/// for a phone that streams it: a low-latency VideoToolbox session (real
/// time, no reordering, an infinite GOP, hardware first), with the surface
/// scaled to at most ``maximumLongSide`` and converted to 4:2:0 in one pixel
/// transfer. Access units are Annex B with the SPS and PPS before each IDR,
/// as the browser host sends them.
@MainActor
final class SurfaceFrameEncoder {
    /// The longest side of the encoded picture: a 3x iPhone screen (2622 px) is
    /// scaled to 1920, which reads sharp on a phone and stays inside H.264 level 4.2.
    nonisolated static let maximumLongSide = 1920
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    private let session: VTCompressionSession
    private let transfer: VTPixelTransferSession
    private var frameIndex: Int64 = 0
    private var kbps = 0

    /// The encoded size for a surface of `width` x `height`: scaled to fit, even sides.
    nonisolated static func encodedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let even = { (value: Int) in max(2, value & ~1) }
        let long = max(width, height, 1)
        guard long > maximumLongSide else { return (even(width), even(height)) }
        // The long side is exactly the limit; the short one keeps the aspect (integer math, no rounding drift).
        let scaled = { (side: Int) in side == long ? maximumLongSide : side * maximumLongSide / long }
        return (even(scaled(width)), even(scaled(height)))
    }

    init?(sourceWidth: Int, sourceHeight: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        (width, height) = Self.encodedSize(width: sourceWidth, height: sourceHeight)
        var transfer: VTPixelTransferSession?
        // SAFETY: VideoToolbox writes one +1 session to the local `transfer`, live for the call.
        guard unsafe VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) == noErr,
              let transfer else { return nil }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        self.transfer = transfer
        teardown.transfer = transfer
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
            [:],
        ]
        var created: VTCompressionSession?
        for spec in specs where created == nil {
            // SAFETY: no output callback and no refcon (frames go to per-frame output handlers);
            // VideoToolbox writes one +1 session to the local `created`, live for the call.
            unsafe VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard let created else { return nil }
        session = created
        teardown.session = created
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 1_000_000 as CFNumber),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
        ]
        for (key, value) in properties { VTSessionSetProperty(created, key: key, value: value) }
        setBitrate(kbps: 4000)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    /// Emits every pending frame now, so each encode hostd asked for is answered
    /// (with an access unit or a skip) before the session goes (a rotation replaces it).
    func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Completes pending frames and invalidates the sessions when the encoder goes: a pending
    /// encode is answered (an access unit or a skip) before its session ends.
    private let teardown = Teardown()

    private final class Teardown {
        var session: VTCompressionSession?
        var transfer: VTPixelTransferSession?

        deinit {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        }
    }

    /// The media engine's target (it follows the path's congestion feedback).
    func setBitrate(kbps: Int) {
        let kbps = min(max(kbps, 300), 40_000)
        guard kbps != self.kbps else { return }
        self.kbps = kbps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: kbps * 1000 as CFNumber)
        // At most 1.5x the target in any one second, so a burst cannot outrun the path.
        let limit = [Double(kbps) * 1000 * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    }

    /// Encodes `surface` now; `completion` runs on a VideoToolbox thread with
    /// the Annex B bytes and whether they are an IDR (nil on failure).
    func encode(_ surface: IOSurface, forceKeyframe: Bool,
                completion: @escaping @Sendable ((data: Data, keyframe: Bool)?) -> Void) {
        var wrapped: Unmanaged<CVPixelBuffer>?
        // SAFETY: Core Video writes one +1 buffer to the local `wrapped`, live for the call; the
        // next line takes that +1 exactly once.
        guard unsafe CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &wrapped) == kCVReturnSuccess,
              // SAFETY: as above, the +1 buffer Core Video just made, taken once.
              let source = unsafe wrapped?.takeRetainedValue(),
              let pool = VTCompressionSessionGetPixelBufferPool(session) else { return completion(nil) }
        var made: CVPixelBuffer?
        // SAFETY: Core Video writes one +1 buffer to the local `made`, live for the call.
        unsafe CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let target = made, VTPixelTransferSessionTransferImage(transfer, from: source, to: target) == noErr else {
            return completion(nil)
        }
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: 60)
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // SAFETY: no info flags out-pointer; the output handler gets the frame.
        let status = unsafe VTCompressionSessionEncodeFrame(
            session, imageBuffer: target, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil, outputHandler: Self.outputHandler(completion))
        if status != noErr { completion(nil) }
    }

    /// The VideoToolbox output handler, made outside the main actor: VideoToolbox calls it on its
    /// own thread, so it must not inherit main-actor isolation from `encode`.
    nonisolated static func outputHandler(
        _ completion: @escaping @Sendable ((data: Data, keyframe: Bool)?) -> Void
    ) -> VTCompressionOutputHandler {
        { status, _, sample in
            guard status == noErr, let sample else { return completion(nil) }
            let keyframe = isKeyframe(sample)
            completion(annexB(sample, keyframe: keyframe).map { ($0, keyframe) })
        }
    }

    nonisolated static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// Length-prefixed encoder output to Annex B, SPS and PPS before a keyframe.
    nonisolated static func annexB(_ sample: CMSampleBuffer, keyframe: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            // The format names how many parameter sets it holds (H.264: SPS and PPS); copy each once.
            var count = 0
            // SAFETY: Core Media writes only the set count, to the local `count`; every other out-pointer is nil.
            _ = unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<min(count, 8) {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                // SAFETY: Core Media writes the set's pointer and size to the locals `pointer` and
                // `size`; the pointer is into the format description, which `sample` keeps alive.
                guard unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    // SAFETY: copies the address Core Media wrote; nothing is read through it here.
                    let pointer = unsafe pointer else { continue }
                out.append(contentsOf: startCode)
                // SAFETY: `pointer` has `size` bytes (Core Media said so above) inside the format
                // description, alive through this function; Data copies them now.
                unsafe out.append(UnsafeBufferPointer(start: pointer, count: size))
            }
        }
        let total = CMBlockBufferGetDataLength(block)
        var raw = [UInt8](repeating: 0, count: total)
        let status = raw.withUnsafeMutableBytes { destination -> OSStatus in
            // SAFETY: nil only for an empty block, which fails the copy as before.
            guard let base = unsafe destination.baseAddress else { return -1 }
            // SAFETY: Core Media copies exactly `total` bytes, the block's whole length, into
            // `raw`, which has `total` bytes, during the call only.
            return unsafe CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard status == noErr else { return nil }
        // AVCC: 4-byte big-endian lengths, each followed by its NAL unit; read from the front of what is left.
        var rest = ArraySlice(raw)
        while rest.count >= 4 {
            let length = Int(truncatingIfNeeded: rest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32(truncatingIfNeeded: $1) })
            rest = rest.dropFirst(4)
            guard length > 0, length <= rest.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return out
    }
}
