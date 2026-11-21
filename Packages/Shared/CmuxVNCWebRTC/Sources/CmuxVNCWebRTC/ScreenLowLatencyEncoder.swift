#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import WebRTC

/// The Mac's H.264 encoder for a screen stream: VideoToolbox's hardware encoder set up
/// for the shortest time from a captured frame to its encoded bytes.
///
/// libwebrtc's own H.264 encoder (the M154 build this package pins) scales every frame
/// on the CPU (libyuv NV12 scaling of a 3456x2234 source to Auto's 2154x1392 at 120 fps)
/// before VideoToolbox sees it, and opens the session with `RealTime` alone. Here the
/// frame is scaled on the GPU (`VTPixelTransferSession`), and the session also has
/// `PrioritizeEncodingSpeedOverQuality`, no frame reordering, the stream's rate as
/// `ExpectedFrameRate`, libwebrtc's target as `AverageBitRate` and libwebrtc's own
/// data rate limit (1.5x the target over a second). On the fleet's M4 that is 7.9 ms
/// p50 / 10 ms p95 from `encode` to the encoded frame, against 18.5 / 31-35 ms for
/// libwebrtc's encoder (`theRateControlsAtStreamBitrates`).
///
/// VideoToolbox's low-latency rate control (`EnableLowLatencyRateControl`, ``RateControl``)
/// is faster still but drops every frame that would overshoot its share of the bitrate:
/// at 2-12 Mbps on scrolling text it kept 30-210 of 240 frames, and a dropped frame
/// never reaches the viewer, so a screen that then stops changing would show the frame
/// before. It stays selectable for the bench, not for streams.
///
/// Used when the stream negotiated a High profile with packetization mode 1
/// (``ScreenEncoderFactory``); anything else keeps libwebrtc's encoder. Each frame's QP
/// is read from its slice header and reported with libwebrtc's own thresholds, so the
/// quality scaler lowers the resolution as it does for libwebrtc's encoder (Smooth
/// keeps its frame rate that way).
// crash-allow: libwebrtc calls start, encode, setBitrate and release on its one encoder queue; `callback` and the session's output (VideoToolbox's thread) meet only under `lock`.
final class ScreenLowLatencyEncoder: NSObject, RTCVideoEncoder, @unchecked Sendable {
    // @unchecked: mutable state is behind `lock`.
    static let implementation = "VideoToolbox screen"

    /// How VideoToolbox paces the bits.
    enum RateControl: String, CaseIterable, Sendable {
        /// `EnableLowLatencyRateControl`: each frame sized to the target as it encodes.
        /// It drops a frame that would overshoot its share (`kVTEncodeInfo_FrameDropped`).
        case lowLatency = "low-latency"
        /// The same, with the frame QP ceiling at 51 so it lowers quality before dropping.
        case lowLatencyQP51 = "low-latency-qp51"
        /// The ordinary real-time session with this encoder's GPU scaling, speed priority
        /// and libwebrtc's data rate limit; it never drops a frame. Streams use this one.
        case realTime = "real-time"
    }

    static let defaultRateControl = RateControl.realTime
    let rateControl: RateControl

    init(rateControl: RateControl = ScreenLowLatencyEncoder.defaultRateControl) {
        self.rateControl = rateControl
        super.init()
    }

    private let lock = NSLock()
    private var callback: RTCVideoEncoderCallback?
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var bitrate = 0
    private var frameRate = 60
    private var scaleBuffer: [UInt8] = []
    private var transfer: VTPixelTransferSession?
    private var failed = false
    private var outcomes = Outcomes()
    private var qpReader = H264SliceQP()

    /// What became of the frames VideoToolbox took: encoded, dropped by its rate
    /// control, failed, or not packable as Annex B.
    struct Outcomes: Equatable {
        var encoded = 0
        var dropped = 0
        var failed = 0
        var unpackable = 0
        var lastStatus: OSStatus = noErr
    }

    var frameOutcomes: Outcomes { lock.withLock { outcomes } }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        lock.withLock { self.callback = callback }
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.withLock {
            width = Int32(settings.width)
            height = Int32(settings.height)
            bitrate = Int(settings.startBitrate) * 1000
            frameRate = max(Int(settings.maxFramerate), 1)
            failed = false
        }
        return makeSession() ? 0 : -1 // WEBRTC_VIDEO_CODEC_OK / ERROR
    }

    func release() -> Int {
        let old = lock.withLock { () -> VTCompressionSession? in
            defer { session = nil }
            return session
        }
        if let old {
            VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(old)
        }
        return 0
    }

    // perf-hot: 1ms screen-stream-encode
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        let keyframe = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        var status = encodeOnce(frame, keyframe: keyframe)
        // VideoToolbox invalidates a session on sleep and wake, a GPU reset or a media
        // server restart. As libwebrtc's own H.264 encoder does, make a new one and try
        // again once; the new session's first frame is a keyframe.
        if status == kVTInvalidSessionErr || lock.withLock({ session == nil }) {
            guard makeSession() else { return -1 } // WEBRTC_VIDEO_CODEC_ERROR
            status = encodeOnce(frame, keyframe: true)
        }
        return status == noErr ? 0 : -1
    }

    /// One frame into the current session; `kVTInvalidSessionErr` when there is none.
    private func encodeOnce(_ frame: RTCVideoFrame, keyframe: Bool) -> OSStatus {
        let (session, width, height) = lock.withLock { (self.session, self.width, self.height) }
        guard let session else { return kVTInvalidSessionErr }
        guard let pixels = pixelBuffer(of: frame, session: session, width: width, height: height) else {
            // No pool: the session is gone (the caller makes a new one).
            return VTCompressionSessionGetPixelBufferPool(session) == nil ? kVTInvalidSessionErr : kVTPixelTransferNotSupportedErr
        }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        let rtpTimestamp = UInt32(bitPattern: frame.timeStamp)
        let captureMs = frame.timeStampNs / 1_000_000
        let rotation = frame.rotation
        return VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
                                               frameProperties: options, infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            guard status == noErr, !flags.contains(.frameDropped), let sample else {
                lock.withLock {
                    if status != noErr { outcomes.failed += 1; outcomes.lastStatus = status } else { outcomes.dropped += 1 }
                }
                return
            }
            deliver(sample, width: width, height: height, rtpTimestamp: rtpTimestamp, captureMs: captureMs, rotation: rotation)
        }
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        let session = lock.withLock { () -> VTCompressionSession? in
            bitrate = Int(bitrateKbit) * 1000
            if framerate > 0 { frameRate = Int(framerate) }
            return self.session
        }
        if let session { applyRate(session) }
        return 0
    }

    func implementationName() -> String { Self.implementation }

    /// libwebrtc's thresholds for its own VideoToolbox H.264 encoder (RTCVideoEncoderH264):
    /// above 39 it scales the picture down, below 28 back up. Each frame's QP comes from
    /// its slice header (``H264SliceQP``), as libwebrtc reads it.
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { RTCVideoEncoderQpThresholds(thresholdsLow: 28, high: 39) }

    var resolutionAlignment: Int { 1 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }

    // MARK: Session

    /// The session's specification and properties (``ScreenLowLatencyEncoder`` above).
    static func specification(_ rateControl: RateControl) -> [CFString: Any] {
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if rateControl != .realTime { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        return specification
    }

    private func makeSession() -> Bool {
        _ = release()
        let (width, height) = lock.withLock { (self.width, self.height) }
        guard width > 0, height > 0 else { return false }
        var made: VTCompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: Self.specification(rateControl) as CFDictionary,
                                                imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else { return false }
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(made, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        if rateControl == .lowLatencyQP51 { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, 51 as CFNumber) }
        // Keyframes only when libwebrtc asks (a new viewer, a lost picture).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber)
        applyRate(made)
        VTCompressionSessionPrepareToEncodeFrames(made)
        lock.withLock { session = made }
        return true
    }

    private func applyRate(_ session: VTCompressionSession) {
        let (bitrate, frameRate) = lock.withLock { (self.bitrate, self.frameRate) }
        if bitrate > 0 { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        // libwebrtc's limit for its VideoToolbox encoder: 1.5x the target in any second.
        if bitrate > 0, rateControl == .realTime {
            let limits = [NSNumber(value: Double(bitrate) * 1.5 / 8), NSNumber(value: 1.0)] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        }
    }

    /// The frame's pixels at the session's size: the source's own buffer when it fits,
    /// else cropped and scaled (libwebrtc's adapter lowered the resolution) or an I420
    /// frame copied into a pooled NV12 buffer.
    private func pixelBuffer(of frame: RTCVideoFrame, session: VTCompressionSession, width: Int32, height: Int32) -> CVPixelBuffer? {
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let crop = buffer.requiresCropping()
            guard crop || buffer.requiresScaling(toWidth: width, height: height) else { return buffer.pixelBuffer }
            guard let out = pooledBuffer(session) else { return nil }
            // A smaller picture (Auto above 60 fps, Smooth Motion under load): scaled on the
            // GPU. libwebrtc's own path scales NV12 on the CPU (libyuv) on every frame. Its
            // adapter also crops a few pixels to align the smaller size; the whole picture is
            // scaled instead (``cropIsAlignment``), which keeps the viewer's pointer fractions exact.
            if !crop || Self.cropIsAlignment(buffer), let transfer = transferSession(),
               VTPixelTransferSessionTransferImage(transfer, from: buffer.pixelBuffer, to: out) == noErr {
                return out
            }
            // A real crop (one display of a wider framebuffer): libyuv's NV12 path, or, for
            // any other source (BGRA), libwebrtc's own crop and convert to I420 below. libyuv's
            // ARGB path would need an ARGB output, and this one is NV12.
            let format = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer)
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
                return copyI420(Self.i420(buffer, width: width, height: height), into: out)
            }
            let size = Int(buffer.bufferSizeForCroppingAndScaling(toWidth: width, height: height))
            if scaleBuffer.count < size { scaleBuffer = [UInt8](repeating: 0, count: size) }
            let ok = scaleBuffer.withUnsafeMutableBufferPointer { temp in buffer.cropAndScale(to: out, withTempBuffer: temp.baseAddress) }
            return ok ? out : nil
        }
        guard let out = pooledBuffer(session) else { return nil }
        return copyI420(frame.buffer.toI420(), into: out)
    }

    /// The buffer's crop as I420 at `width` x `height`: libwebrtc crops and converts it,
    /// then scales it when its size is not the session's.
    static func i420(_ buffer: RTCCVPixelBuffer, width: Int32, height: Int32) -> any RTCI420BufferProtocol {
        let picture = buffer.toI420()
        guard picture.width != width || picture.height != height,
              let scaled = picture.cropAndScale?(with: 0, offsetY: 0, cropWidth: picture.width, cropHeight: picture.height,
                                                 scaleWidth: width, scaleHeight: height)
        else { return picture }
        return scaled.toI420()
    }

    /// An I420 picture copied into an NV12 buffer of (at most) its size.
    private func copyI420(_ i420: any RTCI420BufferProtocol, into out: CVPixelBuffer) -> CVPixelBuffer {
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let rows = min(Int(i420.height), CVPixelBufferGetHeightOfPlane(out, 0))
        let columns = min(Int(i420.width), CVPixelBufferGetWidthOfPlane(out, 0))
        if let y = CVPixelBufferGetBaseAddressOfPlane(out, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
            for row in 0 ..< rows { memcpy(y + row * stride, i420.dataY + row * Int(i420.strideY), columns) }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
            for row in 0 ..< (rows + 1) / 2 {
                let u = i420.dataU + row * Int(i420.strideU), v = i420.dataV + row * Int(i420.strideV)
                let line = uv + row * stride
                for column in 0 ..< (columns + 1) / 2 {
                    line[2 * column] = u[column]
                    line[2 * column + 1] = v[column]
                }
            }
        }
        return out
    }

    /// A crop of at most 2% of each side: libwebrtc's adapter aligning a smaller size, not
    /// a crop anyone asked for.
    static func cropIsAlignment(_ buffer: RTCCVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer.pixelBuffer), height = CVPixelBufferGetHeight(buffer.pixelBuffer)
        return Double(buffer.cropWidth) >= Double(width) * 0.98 && Double(buffer.cropHeight) >= Double(height) * 0.98
    }

    /// The GPU scaler, made on first use (encoder queue only).
    private func transferSession() -> VTPixelTransferSession? {
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer { VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal) }
        }
        return transfer
    }

    /// A buffer from the session's own pool (VideoToolbox may replace the pool).
    private func pooledBuffer(_ session: VTCompressionSession) -> CVPixelBuffer? {
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    // MARK: Output

    private func deliver(_ sample: CMSampleBuffer, width: Int32, height: Int32, rtpTimestamp: UInt32, captureMs: Int64, rotation: RTCVideoRotation) {
        let keyframe = Self.isKeyframe(sample)
        guard let annexB = Self.annexB(sample, withParameterSets: keyframe) else {
            lock.withLock { outcomes.unpackable += 1 }
            return
        }
        // libwebrtc's quality scaler reads each frame's QP (VideoToolbox reports none).
        let qp = lock.withLock { () -> Int? in
            outcomes.encoded += 1
            return qpReader.qp(annexB: [UInt8](annexB))
        }
        let image = RTCEncodedImage()
        image.buffer = annexB
        image.encodedWidth = width
        image.encodedHeight = height
        image.timeStamp = rtpTimestamp
        image.captureTimeMs = captureMs
        image.frameType = keyframe ? .videoFrameKey : .videoFrameDelta
        image.rotation = rotation
        image.contentType = .screenshare
        image.qp = NSNumber(value: qp ?? -1)
        let info = RTCCodecSpecificInfoH264()
        info.packetizationMode = .nonInterleaved
        guard let callback = lock.withLock({ callback }) else { return }
        _ = callback(image, info)
    }

    /// A sample without `NotSync` is a sync (IDR) frame.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// The sample's AVCC NAL units (each after a big-endian length) as an Annex B
    /// stream (each after a 4-byte start code), with the SPS and PPS first on a keyframe.
    static func annexB(_ sample: CMSampleBuffer, withParameterSets: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        var headerLength: Int32 = 4
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        if withParameterSets {
            for index in 0 ..< count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &avcc) == noErr else { return nil }
        let prefix = Int(headerLength)
        guard prefix > 0, prefix <= 4 else { return nil }
        var offset = 0
        while offset + prefix <= length {
            var nal = 0
            for index in 0 ..< prefix { nal = nal << 8 | Int(avcc[offset + index]) }
            offset += prefix
            guard nal > 0, offset + nal <= length else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[offset ..< offset + nal])
            offset += nal
        }
        return out
    }
}
#endif
