import AVFoundation
import CoreMedia
import Foundation
import os
import VideoToolbox

private let log = Logger(subsystem: "dev.cmux.mobile", category: "browser-stream")

/// Hardware H.264 decode (VideoToolbox) of a streamed browser tab into an
/// `AVSampleBufferDisplayLayer`, on one serial queue. A frame that cannot be
/// decoded (no keyframe yet, a lost reference) asks for a keyframe and skips
/// to it.
public final class BrowserVideoDecoder: @unchecked Sendable {
    /// One shown frame: when it was captured relative to now, and decode time.
    public struct Shown: Sendable {
        public var frame: UInt32
        /// Capture on the Mac to decoded on the phone, when the clock is known.
        public var latencyMicros: Int64?
        public var decodeMicros: UInt32
        public var bytes: Int
        public var width: Int32
        public var height: Int32
    }

    public let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "dev.cmux.mobile.browser-decode", qos: .userInteractive)
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var needKeyframe = true
    /// Frames skipped while waiting for a keyframe (diagnostics).
    private var skipped = 0
    private var lastPixels: CVPixelBuffer?
    /// Asks the host for a keyframe.
    public var requestKeyframe: @Sendable () -> Void = {}
    /// The stream clock (to measure decode time and latency).
    public var now: @Sendable () -> UInt64 = { 0 }
    /// After each shown frame, on the decode queue.
    public var shown: @Sendable (Shown) -> Void = { _ in }

    public init(layer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()) {
        self.layer = layer
        layer.videoGravity = .resizeAspect
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes and shows `accessUnit` (Annex-B).
    public func submit(frame: UInt32, accessUnit: Data, keyframe: Bool, receivedMicros: UInt64, ageMicros: Int64?) {
        queue.async { [self] in
            decode(frame: frame, accessUnit: accessUnit, keyframe: keyframe, received: receivedMicros, age: ageMicros)
        }
    }

    /// The last decoded picture (grid cards).
    public func lastPicture(_ done: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        queue.async { [self] in done(lastPixels) }
    }

    /// Drops the decoder (link gone, or the page stalled); the next keyframe
    /// starts it again.
    public func reset() {
        queue.async { [self] in dropSession() }
    }

    private func dropSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sps = nil
        pps = nil
        needKeyframe = true
    }

    /// Tests: invalidate the session under the decoder, as iOS does to a
    /// decoder while the app is in the background.
    func invalidateSessionForTesting() {
        queue.sync { if let session { VTDecompressionSessionInvalidate(session) } }
    }

    private func decode(frame: UInt32, accessUnit: Data, keyframe: Bool, received: UInt64, age: Int64?) {
        let unit = AnnexBAccessUnit(accessUnit)
        if let sps = unit.sps, let pps = unit.pps, sps != self.sps || pps != self.pps || session == nil {
            guard makeSession(sps: sps, pps: pps) else { return }
        }
        if needKeyframe, !unit.isIDR {
            skipped += 1
            if skipped.nonzeroBitCount == 1 {
                log.info("skipped \(self.skipped) frames waiting for a keyframe (frame \(frame), keyframe flag \(keyframe))")
            }
            return
        }
        guard let session, let format, !unit.units.isEmpty else {
            if !unit.isIDR { requestKeyframe() }
            return
        }
        let avcc = unit.avcc
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        let started = now()
        var shownPixels: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { shownPixels = image }
        }
        guard status == noErr, let pixels = shownPixels else {
            log.error("decode failed (\(status)) on frame \(frame); asking for a keyframe")
            // The session itself may be what failed (iOS invalidates a decoder
            // while the app is in the background, kVTInvalidSessionErr): the
            // next keyframe starts a new one, so a dead session never turns
            // every keyframe into another request.
            dropSession()
            requestKeyframe()
            return
        }
        needKeyframe = false
        skipped = 0
        lastPixels = pixels
        enqueue(pixels)
        let done = now()
        let decodeMicros = UInt32(clamping: done &- started)
        let latency = age.map { $0 + Int64(clamping: done &- received) }
        shown(Shown(frame: frame, latencyMicros: latency, decodeMicros: decodeMicros, bytes: accessUnit.count,
                    width: Int32(CVPixelBufferGetWidth(pixels)), height: Int32(CVPixelBufferGetHeight(pixels))))
    }

    private func makeSession(sps: Data, pps: Data) -> Bool {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            log.error("bad parameter sets (\(status))")
            return false
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let made = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard made == noErr, let created else {
            log.error("no decoder (\(made))")
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        format = description
        self.sps = sps
        self.pps = pps
        needKeyframe = true
        return true
    }

    private func enqueue(_ pixels: CVPixelBuffer) {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description)
        guard let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: description,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
