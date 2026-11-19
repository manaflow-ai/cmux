#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import WebRTC

/// The Mac's H.264 encoder for a screen stream: VideoToolbox's hardware encoder in its
/// low-latency mode, the mode Apple recommends for "ultra-low-latency conferencing and
/// cloud gaming (cases where every millisecond counts)" (VTCompressionProperties.h).
///
/// libwebrtc's own H.264 encoder (the M154 build this package pins) opens VideoToolbox
/// as for live capture: `RealTime`, no reordering, an average bitrate and a one-second
/// data rate limit, and nothing more; it never enables low-latency rate control (its
/// binary does not reference `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`).
/// Here the session is created with that specification, plus `RealTime`,
/// `PrioritizeEncodingSpeedOverQuality`, no frame reordering, the stream's frame rate
/// as `ExpectedFrameRate` and libwebrtc's target as `AverageBitRate`. Low-latency rate
/// control sizes each frame to the target as it encodes (frame-level rate control,
/// infinite GOP, no lookahead), so a frame comes out sooner and a burst does not
/// leave a long frame queued behind the pacer.
///
/// Low-latency mode encodes High profile only, so this encoder is used only when the
/// stream negotiated a High profile with packetization mode 1 (``ScreenEncoderFactory``);
/// anything else keeps libwebrtc's encoder. VideoToolbox reports no per-frame QP, so
/// libwebrtc's QP-based quality scaler is off for this encoder (`scalingSettings` nil):
/// resolution still adapts to CPU load and to the bandwidth estimate.
// crash-allow: libwebrtc calls start, encode, setBitrate and release on its one encoder queue; `callback` and the session's output (VideoToolbox's thread) meet only under `lock`.
final class ScreenLowLatencyEncoder: NSObject, RTCVideoEncoder, @unchecked Sendable {
    // @unchecked: mutable state is behind `lock`.
    static let implementation = "VideoToolbox low-latency"

    /// How VideoToolbox paces the bits.
    enum RateControl: String, CaseIterable, Sendable {
        /// `EnableLowLatencyRateControl`: each frame sized to the target as it encodes.
        /// It drops a frame that would overshoot its share (`kVTEncodeInfo_FrameDropped`).
        case lowLatency = "low-latency"
        /// The same, with the frame QP ceiling at 51 so it lowers quality before dropping.
        case lowLatencyQP51 = "low-latency-qp51"
        /// The ordinary real-time session (libwebrtc's settings) with this encoder's GPU
        /// scaling and speed priority; it overshoots instead of dropping.
        case realTime = "real-time"
    }

    static let defaultRateControl = RateControl.lowLatency
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
    private var pool: CVPixelBufferPool?
    private var scaleBuffer: [UInt8] = []
    private var transfer: VTPixelTransferSession?
    private var failed = false
    private var outcomes = Outcomes()

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
        let (session, width, height) = lock.withLock { (self.session, self.width, self.height) }
        guard let session, let pixels = pixelBuffer(of: frame, width: width, height: height) else { return -1 }
        let keyframe = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        let rtpTimestamp = UInt32(bitPattern: frame.timeStamp)
        let captureMs = frame.timeStampNs / 1_000_000
        let rotation = frame.rotation
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
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
        return status == noErr ? 0 : -1
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

    /// No QP per frame from VideoToolbox, so no QP-based quality scaling.
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }

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
        lock.withLock {
            session = made
            pool = VTCompressionSessionGetPixelBufferPool(made)
        }
        return true
    }

    private func applyRate(_ session: VTCompressionSession) {
        let (bitrate, frameRate) = lock.withLock { (self.bitrate, self.frameRate) }
        if bitrate > 0 { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
    }

    /// The frame's pixels at the session's size: the source's own buffer when it fits,
    /// else cropped and scaled (libwebrtc's adapter lowered the resolution) or an I420
    /// frame copied into a pooled NV12 buffer.
    private func pixelBuffer(of frame: RTCVideoFrame, width: Int32, height: Int32) -> CVPixelBuffer? {
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let crop = buffer.requiresCropping()
            guard crop || buffer.requiresScaling(toWidth: width, height: height) else { return buffer.pixelBuffer }
            guard let out = pooledBuffer() else { return nil }
            // A smaller picture (Auto above 60 fps, Smooth Motion under load): scaled on the
            // GPU. libwebrtc's own path scales NV12 on the CPU (libyuv) on every frame. Its
            // adapter also crops a few pixels to align the smaller size; the whole picture is
            // scaled instead (``cropIsAlignment``), which keeps the viewer's pointer fractions exact.
            if !crop || Self.cropIsAlignment(buffer), let transfer = transferSession(), VTPixelTransferSessionTransferImage(transfer, from: buffer.pixelBuffer, to: out) == noErr {
                return out
            }
            let size = Int(buffer.bufferSizeForCroppingAndScaling(toWidth: width, height: height))
            if scaleBuffer.count < size { scaleBuffer = [UInt8](repeating: 0, count: size) }
            let ok = scaleBuffer.withUnsafeMutableBufferPointer { temp in buffer.cropAndScale(to: out, withTempBuffer: temp.baseAddress) }
            return ok ? out : nil
        }
        guard let out = pooledBuffer() else { return nil }
        let i420 = frame.buffer.toI420()
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

    private func pooledBuffer() -> CVPixelBuffer? {
        guard let pool = lock.withLock({ pool }) else { return nil }
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
        lock.withLock { outcomes.encoded += 1 }
        let image = RTCEncodedImage()
        image.buffer = annexB
        image.encodedWidth = width
        image.encodedHeight = height
        image.timeStamp = rtpTimestamp
        image.captureTimeMs = captureMs
        image.frameType = keyframe ? .videoFrameKey : .videoFrameDelta
        image.rotation = rotation
        image.contentType = .screenshare
        image.qp = NSNumber(value: -1) // VideoToolbox reports none
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
