@testable import CmuxNextRemoteView
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import QuartzCore
import Testing
import VideoToolbox

/// The remote desktop pane's colour, end to end (Leo asked about the HN thread "What every coder
/// should know about gamma"): an sRGB test card (grey ramp 0..255, black 0 and 16, grey 128,
/// white, red, green, blue, teal) reaches the pane's Metal renderer three ways, and every patch
/// must come back within 2 code values of the source on every channel:
///
/// - as NV12 converted exactly (BT.709 and BT.601, video and full range), tagged the way a
///   decoded buffer is: the renderer's conversion alone;
/// - through VideoToolbox's encoder and the pane's own decoder (`RemoteVideoDecoder`), tagged
///   as the Mac host tags its session: the Mac host's stream;
/// - as the Linux host's bitstream (cmux-encode's OpenH264, fixtures in
///   RemoteColorCardFixtures.swift): BT.709 tagged (a current host) and BT.601 untagged (a
///   host before cmux#44978).
///
/// The report and the rendered card (one row per case under the source) print as
/// `color-card:` lines, and the PNG as one base64 `color-card-png:` line (the fleet returns logs,
/// not files, from a failing run).
@MainActor @Suite(.serialized) struct RemoteColorCardTests {
    static let width = 512
    static let height = 96
    static let rampRows = 32
    static let patches: [(String, [UInt8])] = [
        ("black 0", [0, 0, 0]), ("black 16", [16, 16, 16]), ("grey 128", [128, 128, 128]),
        ("white", [255, 255, 255]), ("red", [255, 0, 0]), ("green", [0, 255, 0]),
        ("blue", [0, 0, 255]), ("teal", [0, 128, 128]),
    ]

    /// The card as RGB, row-major.
    static let card: [[UInt8]] = makeCard()

    static func makeCard() -> [[UInt8]] {
        var out: [[UInt8]] = []
        out.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                if y < rampRows {
                    let value = UInt8(x / 2)
                    out.append([value, value, value])
                } else {
                    out.append(patches[x / 64].1)
                }
            }
        }
        return out
    }

    enum Matrix: String, CaseIterable {
        case bt709, bt601
        var key: CFString { self == .bt709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4 }
        var kr: Double { self == .bt709 ? 0.2126 : 0.299 }
        var kb: Double { self == .bt709 ? 0.0722 : 0.114 }
    }

    // MARK: - The cases

    @Test func theRendererConvertsEveryMatrixAndRange() throws {
        var report = Report()
        for matrix in Matrix.allCases {
            for fullRange in [false, true] {
                let buffer = try Self.exactNV12(matrix: matrix, fullRange: fullRange)
                report.add("exact NV12, \(matrix.rawValue), \(fullRange ? "full" : "video") range", try Self.render(buffer))
            }
        }
        report.finish(bound: 2)
    }

    @Test func theMacHostsStreamComesBackAsTheCard() throws {
        var report = Report()
        for matrix in Matrix.allCases {
            for fullRange in [false, true] {
                let stream = try Self.encodeWithVideoToolbox(matrix: matrix, fullRange: fullRange)
                let name = "VideoToolbox, \(matrix.rawValue), \(fullRange ? "full" : "video") range"
                report.note("\(name): SPS says transfer \(stream.transfer), matrix \(stream.matrix), full range \(stream.fullRange)")
                report.add(name, try Self.render(Self.decode(stream.annexB)))
            }
        }
        report.finish(bound: 2)
    }

    @Test func theLinuxHostsStreamComesBackAsTheCard() throws {
        var report = Report()
        let tagged = try #require(Data(base64Encoded: RemoteColorCardFixtures.linuxHostBT709Tagged))
        let untagged = try #require(Data(base64Encoded: RemoteColorCardFixtures.linuxHostBT601Untagged))
        report.add("Linux host, BT.709 tagged", try Self.render(Self.decode(tagged)))
        report.add("Linux host before #44978, BT.601 untagged", try Self.render(Self.decode(untagged)))
        report.finish(bound: 2)
    }

    /// The Mac host's session asks for the sRGB transfer (screen pixels are sRGB-encoded), and
    /// VideoToolbox writes it into the SPS (H.264 transfer 13).
    @Test func theMacHostTagsTheSRGBTransfer() throws {
        let stream = try Self.encodeWithVideoToolbox(matrix: .bt709, fullRange: false)
        #expect(stream.transfer == kCVImageBufferTransferFunction_sRGB as String)
        #expect(stream.matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    /// The pane's layer is colour-matched from the stream's primaries: sRGB for BT.709, Display P3
    /// for P3 D65. Unset, macOS shows the pixels as the display's own space (oversaturated on P3).
    @Test func theLayerTakesTheStreamsColourSpace() throws {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        let renderer = try #require(MetalYUVRenderer(layer: layer))
        let buffer = try Self.exactNV12(matrix: .bt709, fullRange: false)
        _ = renderer.render(RemoteDecodedFrame(pixelBuffer: buffer, frame: 0, tCaptureMicros: 0, decodedAtNanos: 0))
        #expect(layer.colorspace?.name == CGColorSpace.sRGB)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        _ = renderer.render(RemoteDecodedFrame(pixelBuffer: buffer, frame: 1, tCaptureMicros: 0, decodedAtNanos: 0))
        #expect(layer.colorspace?.name == CGColorSpace.displayP3)
    }

    // MARK: - Report

    struct Report {
        var lines: [String] = []
        var rows: [[[UInt8]]] = [RemoteColorCardTests.card]
        var worst: [(String, Int)] = []

        mutating func note(_ line: String) { lines.append(line) }

        mutating func add(_ name: String, _ got: [[UInt8]]) {
            rows.append(got)
            lines.append(name)
            var caseWorst = 0
            for (region, points) in RemoteColorCardTests.regions {
                var max = [0, 0, 0], sum = [0, 0, 0]
                for i in points {
                    for c in 0..<3 {
                        let d = abs(Int(got[i][c]) - Int(RemoteColorCardTests.card[i][c]))
                        max[c] = Swift.max(max[c], d)
                        sum[c] += d
                    }
                }
                let mean: [String] = sum.map { (total: Int) -> String in
                    String(format: "%.2f", Double(total) / Double(points.count))
                }
                lines.append("  \(region.padding(toLength: 18, withPad: " ", startingAt: 0)) R \(max[0]) / \(mean[0])  G \(max[1]) / \(mean[1])  B \(max[2]) / \(mean[2])")
                caseWorst = Swift.max(caseWorst, max.max() ?? 0)
            }
            worst.append((name, caseWorst))
        }

        func finish(bound: Int) {
            for line in lines { print("color-card: \(line)") }
            if let png = RemoteColorCardTests.png(rows) {
                print("color-card-png: \(png.base64EncodedString())")
            }
            for (name, max) in worst {
                #expect(max <= bound, "\(name): \(max) code values off (bound \(bound))")
            }
        }
    }

    /// Interior points of each region (8 px in from patch edges), the ramp first.
    static let regions: [(String, [Int])] = {
        var ramp: [Int] = []
        for step in 0..<256 { ramp.append((rampRows / 2) * width + step * 2) }
        var out: [(String, [Int])] = [("grey ramp 0..255", ramp)]
        for (index, patch) in patches.enumerated() {
            var points: [Int] = []
            for y in (rampRows + 8)..<(height - 8) {
                for x in (index * 64 + 8)..<(index * 64 + 56) { points.append(y * width + x) }
            }
            out.append((patch.0, points))
        }
        return out
    }()

    // MARK: - Sources

    static func makeBuffer(_ format: OSType) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &out)
        return try #require(out)
    }

    static func tag(_ buffer: CVPixelBuffer, matrix: Matrix?) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        if let matrix { CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix.key, .shouldPropagate) }
    }

    /// The card in NV12, converted exactly (4:2:0 chroma from the average of each 2 x 2 block).
    static func exactNV12(matrix: Matrix, fullRange: Bool) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        tag(buffer, matrix: matrix)
        let (kr, kb) = (matrix.kr, matrix.kb)
        let kg = 1 - kr - kb
        func luma(_ p: [Double]) -> Double { (kr * p[0] + kg * p[1] + kb * p[2]) / 255 }
        func code(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let (ys, uvs) = (CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        for row in 0..<height {
            for col in 0..<width {
                let l = luma(card[row * width + col].map(Double.init))
                y[row * ys + col] = code(fullRange ? 255 * l : 16 + 219 * l)
            }
        }
        for row in 0..<height / 2 {
            for col in 0..<width / 2 {
                var rgb = [0.0, 0.0, 0.0]
                for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let p = card[(2 * row + dy) * width + 2 * col + dx]
                    for c in 0..<3 { rgb[c] += Double(p[c]) / 4 }
                }
                let l = luma(rgb)
                let cb = (rgb[2] / 255 - l) / (2 * (1 - kb))
                let cr = (rgb[0] / 255 - l) / (2 * (1 - kr))
                let scale = fullRange ? 255.0 : 224.0
                uv[row * uvs + 2 * col] = code(128 + scale * cb)
                uv[row * uvs + 2 * col + 1] = code(128 + scale * cr)
            }
        }
        return buffer
    }

    struct Stream {
        let annexB: Data
        let transfer: String
        let matrix: String
        let fullRange: Bool
    }

    /// The card through VideoToolbox as the Mac host encodes: BGRA (sRGB) to NV12 in the given
    /// matrix and range, then H.264 with the session tagged primaries BT.709, transfer sRGB and
    /// that matrix. Returns the last frame (a forced keyframe once rate control settled), and
    /// what its SPS says as the viewer's format description reads it.
    static func encodeWithVideoToolbox(matrix: Matrix, fullRange: Bool) throws -> Stream {
        let bgra = try makeBuffer(kCVPixelFormatType_32BGRA)
        tag(bgra, matrix: nil)
        CVPixelBufferLockBaseAddress(bgra, [])
        let base = try #require(CVPixelBufferGetBaseAddress(bgra)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(bgra)
        for row in 0..<height {
            for col in 0..<width {
                let p = card[row * width + col]
                let o = row * stride + col * 4
                base[o] = p[2]
                base[o + 1] = p[1]
                base[o + 2] = p[0]
                base[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])
        let nv12 = try makeBuffer(fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        tag(nv12, matrix: matrix)
        var transferOut: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferOut)
        let transfer = try #require(transferOut)
        defer { VTPixelTransferSessionInvalidate(transfer) }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: matrix.key)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        #expect(VTPixelTransferSessionTransferImage(transfer, from: bgra, to: nv12) == noErr)

        let collected = CollectedSamples()
        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &sessionOut)
        let session = try #require(status == noErr ? sessionOut : nil)
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 40_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: matrix.key)
        let frames = 12
        for index in 0..<frames {
            let force: CFDictionary? = index == frames - 1 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: nv12, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: .invalid, frameProperties: force, infoFlagsOut: nil) { _, _, sample in
                if let sample { collected.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let sample = try #require(collected.all.last)
        let bytes = try Self.annexB(sample)
        let parsed = RemoteAnnexB().parse(bytes, codec: .h264)
        let format = try #require(RemoteVideoFormat.formatDescription(codec: .h264, parameterSets: parsed.parameterSets))
        func ext(_ key: CFString) -> String { (CMFormatDescriptionGetExtension(format, extensionKey: key) as? String) ?? "untagged" }
        let full = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) ?? false
        return Stream(annexB: bytes, transfer: ext(kCMFormatDescriptionExtension_TransferFunction),
                      matrix: ext(kCMFormatDescriptionExtension_YCbCrMatrix), fullRange: full)
    }

    /// A sample's SPS, PPS and NAL units as Annex-B (start codes), as the host sends them.
    static func annexB(_ sample: CMSampleBuffer) throws -> Data {
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        var out = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(try #require(pointer), count: size)
        }
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
        var offset = 0
        while offset + 4 <= bytes.count {
            var length = 0
            for byte in bytes[offset..<(offset + 4)] { length = (length << 8) | Int(byte) }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[offset + 4..<min(bytes.count, offset + 4 + length)])
            offset += 4 + length
        }
        return out
    }

    /// Decodes one keyframe with the pane's decoder.
    static func decode(_ annexB: Data) throws -> CVPixelBuffer {
        let decoder = RemoteVideoDecoder()
        return try decoder.decode(RemoteAccessUnit(frame: 0, flags: .keyframe, tCaptureMicros: 0, data: annexB, codec: .h264))
    }

    // MARK: - The pane's renderer, offscreen

    /// Draws `buffer` with the pane's `MetalYUVRenderer` into a BGRA texture and reads it back as RGB.
    static func render(_ buffer: CVPixelBuffer) throws -> [[UInt8]] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        let renderer = try #require(MetalYUVRenderer(layer: layer))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let commands = try #require(renderer.commandQueue.makeCommandBuffer())
        #expect(renderer.encodeDraw(buffer, into: target, commands: commands))
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.synchronize(resource: target)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var out: [[UInt8]] = []
        out.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let o = index * 4
            out.append([bytes[o + 2], bytes[o + 1], bytes[o]])
        }
        return out
    }

    /// The rows (each the card's size) stacked into one PNG.
    static func png(_ rows: [[[UInt8]]]) -> Data? {
        var bytes: [UInt8] = []
        for row in rows {
            for p in row {
                bytes.append(p[0])
                bytes.append(p[1])
                bytes.append(p[2])
                bytes.append(255)
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height * rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

private nonisolated final class CollectedSamples: @unchecked Sendable {
    // @unchecked: `samples` is only touched under `lock`; each sample is read after the encoder is done.
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    func append(_ sample: CMSampleBuffer) { lock.withLock { samples.append(sample) } }
    var all: [CMSampleBuffer] { lock.withLock { samples } }
}
