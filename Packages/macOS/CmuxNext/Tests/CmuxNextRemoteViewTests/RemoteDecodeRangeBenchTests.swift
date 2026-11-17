@testable import CmuxNextRemoteView
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

/// The before/after for `RemoteVideoDecoder.outputPixelFormat`: 4K video-range (`420v`) frames,
/// encoded the way the Mac host encodes them, decoded once asking for full range (before) and once
/// for the stream's own range (after). Off by default; `CMUX_RD_DECODE_BENCH=1` runs it and prints
/// per-frame decode times.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_RD_DECODE_BENCH"] == "1"))
nonisolated struct RemoteDecodeRangeBenchTests {
    private static let width = 3840
    private static let height = 2160
    private static let frames = 120

    @Test func streamRangeDecodesFasterThanFullRange() throws {
        let samples = try Self.encode()
        let format = try #require(CMSampleBufferGetFormatDescription(samples[0]))
        #expect(RemoteVideoDecoder.outputPixelFormat(for: format) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                "the encoder's own description says video range")
        // Warm both, then alternate rounds so thermal drift hits both sides alike.
        var before: [Double] = []
        var after: [Double] = []
        for round in 0..<6 {
            let full = try Self.decode(samples, format: format, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            let own = try Self.decode(samples, format: format, pixelFormat: RemoteVideoDecoder.outputPixelFormat(for: format))
            if round > 0 { before += full; after += own }
        }
        let b = Self.stats(before), a = Self.stats(after)
        print("rd-decode-range-bench 4K \(Self.frames) frames x 5 rounds: full range p50 \(b.p50) ms p95 \(b.p95) ms; stream range p50 \(a.p50) ms p95 \(a.p95) ms")
    }

    private static func stats(_ values: [Double]) -> (p50: String, p95: String) {
        let sorted = values.sorted()
        func at(_ q: Double) -> String { String(format: "%.3f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) }
        return (at(0.5), at(0.95))
    }

    private static func encode() throws -> [CMSampleBuffer] {
        let collected = Collected()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        let encoder = try #require(status == noErr ? session : nil)
        defer { VTCompressionSessionInvalidate(encoder) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        for index in 0..<frames {
            let buffer = try frame(index)
            let time = CMTime(value: CMTimeValue(index), timescale: 60)
            VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
                frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                if let sample { collected.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        let samples = collected.all
        #expect(samples.count == frames)
        return samples
    }

    /// A moving gradient, so each frame carries real change.
    private static func frame(_ index: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &out)
        let buffer = try #require(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for row in 0..<rows {
                let line = base + row * stride
                for column in 0..<stride { line[column] = UInt8(truncatingIfNeeded: column &+ row &+ index * 7) }
            }
        }
        return buffer
    }

    /// Per-frame decode time in ms, the way the viewer decodes: synchronous, real time.
    private static func decode(_ samples: [CMSampleBuffer], format: CMVideoFormatDescription, pixelFormat: OSType) throws -> [Double] {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        let decoder = try #require(status == noErr ? session : nil)
        defer { VTDecompressionSessionInvalidate(decoder) }
        VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var times: [Double] = []
        for sample in samples {
            let start = DispatchTime.now().uptimeNanoseconds
            let got = PixelFormatBox()
            let decoded = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image { got.set(CVPixelBufferGetPixelFormatType(image)) }
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            #expect(decoded == noErr && got.value == pixelFormat)
        }
        return times
    }
}

private nonisolated final class Collected: @unchecked Sendable {
    // @unchecked: `samples` is only touched under `lock`; CMSampleBuffer is not Sendable, and each one is
    // only read after the encoder is done with it.
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    func append(_ sample: CMSampleBuffer) { lock.withLock { samples.append(sample) } }
    var all: [CMSampleBuffer] { lock.withLock { samples } }
}

/// The decode handler's output format; VideoToolbox calls the handler before `DecodeFrame` returns.
private nonisolated final class PixelFormatBox: @unchecked Sendable {
    // @unchecked: `stored` is only touched under `lock`.
    private let lock = NSLock()
    private var stored: OSType = 0
    func set(_ format: OSType) { lock.withLock { stored = format } }
    var value: OSType { lock.withLock { stored } }
}
