public import CoreGraphics
public import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// One decoded picture: an IOSurface-backed NV12 pixel buffer (full range,
/// Metal compatible) and the timing the presenter and stats need.
public nonisolated struct RemoteDecodedFrame: @unchecked Sendable {
    // @unchecked: the pixel buffer is never written after the decoder
    // returns it; presenters only read it (IOSurface, Metal texture, layer).
    public let pixelBuffer: CVPixelBuffer
    public let frame: UInt32
    public let tCaptureMicros: UInt64
    /// `DispatchTime.now().uptimeNanoseconds` when decode finished.
    public let decodedAtNanos: UInt64

    public init(pixelBuffer: CVPixelBuffer, frame: UInt32, tCaptureMicros: UInt64, decodedAtNanos: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.frame = frame
        self.tCaptureMicros = tCaptureMicros
        self.decodedAtNanos = decodedAtNanos
    }

    public var pixelSize: CGSize {
        CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }
}

/// A VTDecompressionSession in real-time mode, hardware first. Decodes
/// synchronously on the caller's thread (the pipeline actor), so a frame is
/// decoded the moment it arrives and nothing queues inside VideoToolbox.
/// Not Sendable: one owner.
nonisolated final class RemoteVideoDecoder {
    enum Failure: Error, Equatable {
        /// A frame arrived before any parameter sets: wait for a keyframe.
        case noFormat
        case badParameterSets
        case sessionCreate(OSStatus)
        case decode(OSStatus)
        case noImage
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private(set) var isHardware = false

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one access unit and returns its picture.
    func decode(_ unit: RemoteAccessUnit) throws(Failure) -> CVPixelBuffer {
        let parsed = RemoteAnnexB.parse(unit.data, codec: unit.codec)
        if !parsed.parameterSets.isEmpty {
            guard let next = RemoteVideoFormat.formatDescription(codec: unit.codec, parameterSets: parsed.parameterSets) else {
                throw .badParameterSets
            }
            try adopt(next)
        }
        guard let session, let format else { throw .noFormat }
        guard let sample = RemoteVideoFormat.sampleBuffer(lengthPrefixed: parsed.lengthPrefixed, format: format) else {
            throw .decode(-1)
        }
        let output = DecodeOutput()
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: &info
        ) { status, _, image, _, _ in
            output.set(status: status, image: image)
        }
        guard status == noErr else { throw .decode(status) }
        let result = output.take()
        guard result.status == noErr else { throw .decode(result.status) }
        guard let image = result.image else { throw .noImage }
        return image
    }

    /// Keeps the session when it accepts the new format, else rebuilds it.
    private func adopt(_ next: CMVideoFormatDescription) throws(Failure) {
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: next) {
            format = next
            return
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        let (created, hardware) = try Self.makeSession(format: next)
        session = created
        format = next
        isHardware = hardware
    }

    private static func makeSession(format: CMVideoFormatDescription) throws(Failure) -> (VTDecompressionSession, Bool) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // Hardware first; a host without a media engine session (a VM) falls back.
        let specs: [[CFString: Any]] = [
            [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true],
            [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true],
        ]
        var lastStatus: OSStatus = noErr
        for spec in specs {
            var created: VTDecompressionSession?
            lastStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &created)
            guard lastStatus == noErr, let created else { continue }
            VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            var usingHardware: CFTypeRef?
            let query = withUnsafeMutablePointer(to: &usingHardware) {
                VTSessionCopyProperty(
                    created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    allocator: kCFAllocatorDefault, valueOut: $0)
            }
            return (created, query == noErr && (usingHardware as? Bool ?? false))
        }
        throw .sessionCreate(lastStatus)
    }
}

/// The output handler's result. Synchronous decode calls the handler before
/// `DecodeFrame` returns; the mutex makes that hand-off explicit.
private nonisolated final class DecodeOutput: Sendable {
    private struct Result: @unchecked Sendable {
        // @unchecked: the image buffer is read-only once VideoToolbox returns it.
        var status: OSStatus = -1
        var image: CVImageBuffer?
    }

    private let state = Mutex(Result())

    func set(status: OSStatus, image: CVImageBuffer?) {
        state.withLock { $0 = Result(status: status, image: image) }
    }

    func take() -> (status: OSStatus, image: CVImageBuffer?) {
        state.withLock { ($0.status, $0.image) }
    }
}
