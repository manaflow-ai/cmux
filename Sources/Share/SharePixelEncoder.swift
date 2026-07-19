import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Pixel-frame payload codecs (share protocol binary kind 0x02):
/// payload = `[codec u8][flags u8][data]`, flags bit0 = keyframe.
enum SharePixelCodec: UInt8 {
    case h264AnnexB = 1
    case stillImage = 2
}

/// One encoded pixel frame ready to wrap into a binary share frame.
struct SharePixelEncodedFrame: Sendable {
    let codec: SharePixelCodec
    let isKeyframe: Bool
    let data: Data

    var payload: Data {
        var out = Data(capacity: data.count + 2)
        out.append(codec.rawValue)
        out.append(isKeyframe ? 1 : 0)
        out.append(data)
        return out
    }
}

/// VideoToolbox H.264 encoder for one pane's pixel stream. Realtime profile,
/// no frame reordering, Annex B output with SPS/PPS prepended on keyframes.
/// Created lazily per pane; torn down and recreated on size changes.
@MainActor
final class ShareH264Encoder {
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var frameIndex: Int64 = 0

    /// Frames per second the caller paces at; informs the encoder's rate control.
    static let nominalFrameRate: Double = 10

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = 0
        height = 0
        frameIndex = 0
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Encodes one BGRA pixel buffer. Returns nil on encoder failure (the
    /// caller falls back to stills) or when VideoToolbox dropped the frame.
    func encode(pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) async -> SharePixelEncodedFrame? {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || bufferWidth != width || bufferHeight != height {
            invalidate()
            guard makeSession(width: bufferWidth, height: bufferHeight) else { return nil }
        }
        guard let session else { return nil }

        let timestamp = CMTime(value: frameIndex, timescale: Int32(Self.nominalFrameRate))
        frameIndex += 1
        var frameProperties: [CFString: Any] = [:]
        if forceKeyframe {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
        }

        return await withCheckedContinuation { continuation in
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: timestamp,
                duration: CMTime(value: 1, timescale: Int32(Self.nominalFrameRate)),
                frameProperties: frameProperties as CFDictionary,
                infoFlagsOut: nil
            ) { status, infoFlags, sampleBuffer in
                guard status == noErr,
                      !infoFlags.contains(.frameDropped),
                      let sampleBuffer,
                      let encoded = ShareH264Encoder.annexBFrame(from: sampleBuffer) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: encoded)
            }
            if status != noErr {
                // The output handler is never invoked when submission fails.
                continuation.resume(returning: nil)
            }
        }
    }

    private func makeSession(width: Int, height: Int) -> Bool {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { return false }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel
        )
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber)
        VTSessionSetProperty(
            created,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: Self.nominalFrameRate as CFNumber
        )
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        self.width = width
        self.height = height
        return true
    }

    // MARK: - AVCC -> Annex B

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    nonisolated static func annexBFrame(from sampleBuffer: CMSampleBuffer) -> SharePixelEncodedFrame? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let isKeyframe = sampleBufferIsKeyframe(sampleBuffer)
        var out = Data()

        var nalUnitHeaderLength: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )
            if isKeyframe {
                // Parameter sets inline on keyframes so any late joiner can
                // start decoding from the next keyframe.
                for index in 0..<parameterSetCount {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                    guard status == noErr, let pointer, size > 0 else { continue }
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return nil }

        let headerLength = Int(nalUnitHeaderLength)
        guard headerLength >= 1, headerLength <= 4 else { return nil }
        var offset = 0
        dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
            while offset + headerLength <= totalLength {
                var nalLength = 0
                for i in 0..<headerLength {
                    nalLength = (nalLength << 8) | Int(bytes[offset + i])
                }
                offset += headerLength
                guard nalLength > 0, offset + nalLength <= totalLength else { break }
                out.append(contentsOf: startCode)
                out.append(UnsafeBufferPointer(start: bytes + offset, count: nalLength))
                offset += nalLength
            }
        }
        guard !out.isEmpty else { return nil }
        return SharePixelEncodedFrame(codec: .h264AnnexB, isKeyframe: isKeyframe, data: out)
    }

    nonisolated private static func sampleBufferIsKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]], let first = attachments.first else {
            return true
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }
}

/// Still-image (JPEG) fallback encoder and shared bitmap helpers.
enum SharePixelStillEncoder {
    /// JPEG via ImageIO; the web viewer decodes stills with
    /// `createImageBitmap`, which type-sniffs, so JPEG is acceptable.
    static func encodeJPEG(_ image: CGImage, quality: Double = 0.7) -> SharePixelEncodedFrame? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return SharePixelEncodedFrame(codec: .stillImage, isKeyframe: true, data: data as Data)
    }

    /// BGRA pixel buffer for VideoToolbox, with even dimensions (4:2:0 chroma).
    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width - (image.width % 2)
        let height = image.height - (image.height % 2)
        guard width > 0, height > 0 else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Cheap change digest: draw into a 32x32 gray bitmap and hash the bytes.
    /// Collisions just cost one redundant encode; misses are impossible for
    /// identical images, so unchanged frames are always skipped.
    static func changeDigest(of image: CGImage) -> UInt64? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let result: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard result else { return nil }
        // FNV-1a
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in pixels {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
