import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import CmuxSimulatorStreamKit

/// End-to-end video path: BGRA bytes -> pixel buffer -> encoder -> wire codec
/// -> sample-buffer factory -> real VideoToolbox decode. This is the same
/// sequence the Mac host and iOS viewer execute, minus the network.
@Suite
struct SimStreamVideoRoundTripTests {
    private let width = 320
    private let height = 640

    private func syntheticFrame(step: Int) -> Data {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for row in 0..<height {
                let rowBase = base + row * bytesPerRow
                for column in 0..<width {
                    let pixel = rowBase + column * 4
                    // Moving gradient so successive frames differ.
                    pixel.storeBytes(
                        of: UInt8((row + step * 7) % 256), toByteOffset: 0, as: UInt8.self)
                    pixel.storeBytes(
                        of: UInt8((column + step * 13) % 256), toByteOffset: 1, as: UInt8.self)
                    pixel.storeBytes(of: UInt8(step % 256), toByteOffset: 2, as: UInt8.self)
                    pixel.storeBytes(of: 255, toByteOffset: 3, as: UInt8.self)
                }
            }
        }
        return pixels
    }

    private func encodeDecodeRoundTrip(codec: SimStreamVideoCodec) async throws {
        let encoder: SimStreamVideoEncoder
        do {
            encoder = try SimStreamVideoEncoder(
                codec: codec, width: width, height: height, bitsPerSecond: 2_000_000)
        } catch {
            // No encoder for this codec on this machine (CI variance); the
            // H.264 leg below always runs, so skipping HEVC is safe.
            if codec == .hevc { return }
            throw error
        }
        let factory = SimStreamPixelBufferFactory()

        var wireFrames: [SimStreamFrame] = []
        var config: SimStreamConfig?
        for step in 0..<5 {
            let pixelBuffer = try factory.makePixelBuffer(
                pixels: syntheticFrame(step: step),
                width: width, height: height, bytesPerRow: width * 4)
            let encoded = try await encoder.encode(
                pixelBuffer,
                presentationMicroseconds: UInt64(step) * 16_666,
                forceKeyframe: step == 0
            )
            if step == 0 {
                #expect(encoded.isKeyframe)
                #expect(!encoded.parameterSets.isEmpty)
                config = SimStreamConfig(
                    codec: codec,
                    pixelWidth: UInt32(width),
                    pixelHeight: UInt32(height),
                    displayScale: 3.0,
                    orientation: .portrait,
                    parameterSets: encoded.parameterSets,
                    nalUnitHeaderLength: encoded.nalUnitHeaderLength
                )
            }
            wireFrames.append(
                SimStreamFrame(
                    sequence: UInt64(step + 1),
                    flags: encoded.isKeyframe ? [.keyframe] : [],
                    presentationMicroseconds: UInt64(step) * 16_666,
                    payload: encoded.data
                ))
        }

        // Round-trip config and frames through the wire codec, as the network
        // would.
        let decodedConfigMessage = try SimStreamWireCodec.decode(
            SimStreamWireCodec.encode(.config(config!)))
        guard case .config(let wireConfig) = decodedConfigMessage else {
            Issue.record("expected config")
            return
        }

        let sampleFactory = try SimStreamSampleBufferFactory(config: wireConfig)
        var format: CMVideoFormatDescription?
        var decompression: VTDecompressionSession?
        var decodedCount = 0

        for wireFrame in wireFrames {
            let decodedMessage = try SimStreamWireCodec.decode(
                SimStreamWireCodec.encode(.frame(wireFrame)))
            guard case .frame(let received) = decodedMessage else {
                Issue.record("expected frame")
                return
            }
            let sampleBuffer = try sampleFactory.makeSampleBuffer(from: received)
            if decompression == nil {
                format = CMSampleBufferGetFormatDescription(sampleBuffer)
                var created: VTDecompressionSession?
                let status = VTDecompressionSessionCreate(
                    allocator: nil,
                    formatDescription: format!,
                    decoderSpecification: nil,
                    imageBufferAttributes: nil,
                    outputCallback: nil,
                    decompressionSessionOut: &created
                )
                #expect(status == noErr)
                decompression = created
            }
            let result = LockedDecodeResult()
            let status = VTDecompressionSessionDecodeFrame(
                decompression!,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                result.record(status: status, hasImage: imageBuffer != nil)
            }
            #expect(status == noErr, "decode submit failed for seq \(wireFrame.sequence)")
            VTDecompressionSessionWaitForAsynchronousFrames(decompression!)
            #expect(result.status == noErr)
            #expect(result.hasImage, "no image for seq \(wireFrame.sequence)")
            decodedCount += 1
        }
        if let decompression {
            VTDecompressionSessionInvalidate(decompression)
        }
        #expect(decodedCount == wireFrames.count)
        // Delta frames must actually be deltas, not repeated keyframes.
        #expect(wireFrames.dropFirst().allSatisfy { !$0.flags.contains(.keyframe) })
    }

    @Test
    func h264EncodeWireDecodeRoundTrip() async throws {
        try await encodeDecodeRoundTrip(codec: .h264)
    }

    @Test
    func hevcEncodeWireDecodeRoundTripWhenAvailable() async throws {
        try await encodeDecodeRoundTrip(codec: .hevc)
    }

    @Test
    func forcedKeyframeMidStreamIsSelfContained() async throws {
        let encoder = try SimStreamVideoEncoder(
            codec: .h264, width: width, height: height, bitsPerSecond: 2_000_000)
        let factory = SimStreamPixelBufferFactory()
        var keyframeFlags: [Bool] = []
        for step in 0..<4 {
            let pixelBuffer = try factory.makePixelBuffer(
                pixels: syntheticFrame(step: step),
                width: width, height: height, bytesPerRow: width * 4)
            let encoded = try await encoder.encode(
                pixelBuffer,
                presentationMicroseconds: UInt64(step) * 16_666,
                forceKeyframe: step == 0 || step == 2
            )
            keyframeFlags.append(encoded.isKeyframe)
            if step == 2 {
                // A recovery keyframe must re-carry parameter sets so a
                // freshly attached viewer can decode without history.
                #expect(!encoded.parameterSets.isEmpty)
            }
        }
        #expect(keyframeFlags == [true, false, true, false])
    }

    @Test
    func pixelBufferFactoryRejectsGeometryLies() {
        let factory = SimStreamPixelBufferFactory()
        #expect(throws: SimStreamPixelBufferError.geometryMismatch) {
            _ = try factory.makePixelBuffer(
                pixels: Data(count: 100), width: 320, height: 640, bytesPerRow: 1280)
        }
    }

    @Test
    func encodeSizeClampsLongSideAndKeepsAspectEven() {
        let clamped = SimStreamPixelBufferFactory.encodeSize(
            sourceWidth: 2048, sourceHeight: 2732, maximumLongSide: 1366)
        #expect(clamped == (width: 1024, height: 1366))
        let untouched = SimStreamPixelBufferFactory.encodeSize(
            sourceWidth: 1179, sourceHeight: 2556, maximumLongSide: 2556)
        #expect(untouched == (width: 1178, height: 2556))  // even-rounded width
        let uncapped = SimStreamPixelBufferFactory.encodeSize(
            sourceWidth: 320, sourceHeight: 640, maximumLongSide: 0)
        #expect(uncapped == (width: 320, height: 640))
    }

    @Test
    func oversizedFramesDownscaleThroughTheFactory() throws {
        let factory = SimStreamPixelBufferFactory()
        let buffer = try factory.makePixelBuffer(
            pixels: syntheticFrame(step: 0),
            width: width, height: height, bytesPerRow: width * 4,
            maximumLongSide: 320
        )
        #expect(CVPixelBufferGetWidth(buffer) == 160)
        #expect(CVPixelBufferGetHeight(buffer) == 320)
    }
}

private final class LockedDecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: OSStatus = -1
    private var _hasImage = false

    var status: OSStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    var hasImage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasImage
    }

    func record(status: OSStatus, hasImage: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _status = status
        _hasImage = hasImage
    }
}
