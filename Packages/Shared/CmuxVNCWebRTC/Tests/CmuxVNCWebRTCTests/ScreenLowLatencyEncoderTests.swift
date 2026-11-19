#if os(macOS)
@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// The Mac's screen encoder: speed-first VideoToolbox with GPU scaling behind libwebrtc's
/// encoder interface (``ScreenLowLatencyEncoder``).
@Suite(.serialized)
struct ScreenLowLatencyEncoderTests {
    static func info(_ profile: String, mode: String = "1") -> RTCVideoCodecInfo {
        RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: ["profile-level-id": profile, "packetization-mode": mode, "level-asymmetry-allowed": "1"])
    }

    @Test func aHighProfileStreamUsesTheLowLatencyEncoder() {
        #expect(ScreenEncoderFactory.usesLowLatencyEncoder(Self.info("640c34")))
        #expect(ScreenEncoderFactory.usesLowLatencyEncoder(Self.info("640C1F")), "hex case does not matter")
        #expect(!ScreenEncoderFactory.usesLowLatencyEncoder(Self.info("42e01f")), "baseline: the stream negotiates High; anything else keeps libwebrtc's encoder")
        #expect(!ScreenEncoderFactory.usesLowLatencyEncoder(Self.info("640c34", mode: "0")), "single NAL mode: frames are not sized to packets")
        #expect(!ScreenEncoderFactory.usesLowLatencyEncoder(RTCVideoCodecInfo(name: "VP8")))
        #expect(ScreenEncoderFactory().createEncoder(Self.info("640c34")) is ScreenLowLatencyEncoder)
        #expect(!(ScreenEncoderFactory().createEncoder(Self.info("42e01f")) is ScreenLowLatencyEncoder))
    }

    /// Annex B out, SPS and PPS before every IDR, an IDR when libwebrtc asks for one, and a
    /// smaller size scaled from the source's full picture.
    @Test(.timeLimit(.minutes(1)))
    func itEncodesAnnexBWithKeyframesOnRequest() throws {
        let bench = EncoderBench(kind: .realTime, sourceWidth: 1920, sourceHeight: 1200, width: 1280, height: 800, fps: 60)
        let result = try bench.run(frames: 40, keyframesAt: [0, 20])
        #expect(result.outputs.count == 40, "every frame came out (\(result.outputs.count))")
        let first = try #require(result.outputs.first)
        #expect(first.width == 1280 && first.height == 800, "scaled to the size libwebrtc asked for")
        #expect(first.keyframe)
        // SPS, PPS, then the IDR (VideoToolbox's real-time session puts an SEI, 6, before it).
        #expect(Array(first.nalTypes.prefix(2)) == [7, 8], "SPS and PPS first: \(first.nalTypes)")
        #expect(first.nalTypes.contains(5) && first.nalTypes.allSatisfy { [5, 6, 7, 8].contains($0) }, "an IDR picture: \(first.nalTypes)")
        #expect(result.outputs[1].nalTypes.allSatisfy { $0 == 1 || $0 == 6 }, "a delta frame is non-IDR slices: \(result.outputs[1].nalTypes)")
        #expect(result.outputs[20].keyframe && result.outputs[20].nalTypes.contains(5), "the requested IDR at frame 20")
        #expect(result.outputs.filter(\.keyframe).count == 2, "no keyframe libwebrtc did not ask for")
        #expect(result.implementation == ScreenLowLatencyEncoder.implementation)
    }

    /// Each frame's QP, read from its slice header, is the QP libwebrtc's own parser
    /// reads for its VideoToolbox encoder, on the same frames; this encoder reports one
    /// for every frame, higher when the bitrate is lower, so the quality scaler (Smooth)
    /// works as it did with libwebrtc's encoder.
    @Test(.timeLimit(.minutes(2)))
    func eachFrameReportsTheQPLibwebrtcReads() throws {
        for kbps: UInt32 in [600, 12000] {
            let theirs = try EncoderBench(kind: .webrtc, sourceWidth: 1920, sourceHeight: 1200, width: 1280, height: 800, fps: 60)
                .run(frames: 60, bitrateKbps: kbps)
            let agreed = theirs.outputs.filter { $0.qp >= 0 && $0.parsedQP == $0.qp }.count
            print("SCREEN-ENCODER-QP libwebrtc kbps=\(kbps) frames=\(theirs.outputs.count) agreed=\(agreed) qps=\(theirs.outputs.prefix(8).map { "\($0.qp)/\($0.parsedQP ?? -1)" })")
            #expect(theirs.outputs.count >= 55)
            #expect(agreed == theirs.outputs.count, "H264SliceQP reads libwebrtc's QP on each of its frames")
        }
        var means: [UInt32: Double] = [:]
        for kbps: UInt32 in [300, 24000] {
            let ours = try EncoderBench(kind: .realTime, sourceWidth: 1920, sourceHeight: 1200, width: 1280, height: 800, fps: 60)
                .run(frames: 60, bitrateKbps: kbps)
            #expect(ours.outputs.allSatisfy { (0 ... 51).contains($0.qp) }, "a QP on every frame: \(ours.outputs.map(\.qp))")
            means[kbps] = Double(ours.outputs.map(\.qp).reduce(0, +)) / Double(max(ours.outputs.count, 1))
            print("SCREEN-ENCODER-QP real-time kbps=\(kbps) frames=\(ours.outputs.count) mean_qp=\(String(format: "%.1f", means[kbps] ?? -1))")
        }
        #expect((means[300] ?? 0) > (means[24000] ?? 99), "a lower bitrate, a higher QP")
        #expect(ScreenLowLatencyEncoder().scalingSettings()?.low == 28 && ScreenLowLatencyEncoder().scalingSettings()?.high == 39)
    }

    /// Every rate control against libwebrtc's encoder at the bitrates a stream runs at:
    /// scrolling text, 3456x2234 scaled to Auto's 120 fps size, 2 s each. Prints
    /// SCREEN-ENCODER-MODES lines: frames out of 240 (the rest were dropped), the
    /// output rate, encode-to-output latency and frame sizes.
    @Test(.timeLimit(.minutes(3)), arguments: EncoderBench.Kind.allCases)
    func theRateControlsAtStreamBitrates(kind: EncoderBench.Kind) throws {
        for kbps: UInt32 in [2000, 5000, 12000] {
            let bench = EncoderBench(kind: kind, sourceWidth: 3456, sourceHeight: 2234, width: 2154, height: 1392, fps: 120)
            let result = try bench.run(frames: 240, bitrateKbps: kbps)
            let steady = result.outputs.filter { !$0.keyframe }
            let latency = StreamLatencySummary(steady.map(\.latencyMs), unreadable: 0)
            let sizes = result.outputs.map(\.bytes).sorted()
            let kb = { (q: Double) -> Double in sizes.isEmpty ? .nan : Double(sizes[min(sizes.count - 1, Int(q * Double(sizes.count)))]) / 1024 }
            let kbit = Double(result.outputs.map(\.bytes).reduce(0, +)) * 8 / 1000 / max(result.seconds, 0.001)
            print("SCREEN-ENCODER-MODES encoder=\(kind.rawValue) kbps=\(kbps) frames_out=\(result.outputs.count)/240 dropped=\(240 - result.outputs.count) out_kbps=\(Int(kbit)) encode \(latency) frame_kb_p50=\(String(format: "%.1f", kb(0.5))) frame_kb_p95=\(String(format: "%.1f", kb(0.95)))")
        }
    }

    /// What VideoToolbox's low-latency mode does with a burst of frames at full size, by
    /// bitrate and content. Prints SCREEN-ENCODER-PROBE lines; a frame its rate control
    /// drops never reaches libwebrtc, so a screen that then stops changing would keep
    /// showing the frame before.
    @Test(.timeLimit(.minutes(1)), arguments: [(3456, 2234, 120), (1920, 1080, 60), (2154, 1392, 120)])
    func aBurstAtFullSize(width: Int, height: Int, fps: Int) async throws {
        for bitrate: UInt32 in [12000, 48000] {
            for (mode, content) in ScreenLowLatencyEncoder.RateControl.allCases.flatMap({ m in ["flat", "text"].map { (m, $0) } }) {
                let encoder = ScreenLowLatencyEncoder(rateControl: mode)
                encoder.setCallback { _, _ in true }
                let settings = RTCVideoEncoderSettings()
                settings.name = kRTCVideoCodecH264Name
                settings.width = UInt16(width)
                settings.height = UInt16(height)
                settings.startBitrate = bitrate
                settings.maxBitrate = bitrate * 2
                settings.minBitrate = 300
                settings.maxFramerate = UInt32(fps)
                settings.mode = .screensharing
                #expect(encoder.startEncode(with: settings, numberOfCores: 4) == 0)
                let pictures = ScrollingPictures(width: width, height: height)
                var flat: CVPixelBuffer?
                let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &flat)
                let frames = 12
                for index in 0 ..< frames {
                    guard let pixels = content == "flat" ? flat : pictures.next() else { continue }
                    let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                                              timeStampNs: Int64(index) * 1_000_000_000 / Int64(fps))
                    let type: RTCFrameType = index == 0 ? .videoFrameKey : .videoFrameDelta
                    _ = encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: type.rawValue)])
                }
                for _ in 0 ..< 30 {
                    let o = encoder.frameOutcomes
                    if o.encoded + o.dropped + o.failed + o.unpackable >= frames { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let o = encoder.frameOutcomes
                print("SCREEN-ENCODER-PROBE mode=\(mode.rawValue) size=\(width)x\(height) fps=\(fps) kbps=\(bitrate) content=\(content) frames=\(frames) encoded=\(o.encoded) dropped=\(o.dropped) failed=\(o.failed) unpackable=\(o.unpackable) status=\(o.lastStatus)")
                _ = encoder.release()
            }
        }
    }
}

/// Encodes a scrolling text-like screen through one H.264 encoder at a fixed rate and
/// times each frame from `encode` to the encoder's output callback.
final class EncoderBench: @unchecked Sendable {
    // @unchecked: outputs are behind `lock`.
    enum Kind: String, CaseIterable { case webrtc, lowLatency = "low-latency", lowLatencyQP51 = "low-latency-qp51", realTime = "real-time" }

    struct Output {
        var rtp: UInt32
        var bytes: Int
        var keyframe: Bool
        var width: Int32
        var height: Int32
        var nalTypes: [UInt8]
        var latencyMs: Double
        /// The QP the encoder reported (-1: none) and the QP ``H264SliceQP`` reads.
        var qp: Int
        var parsedQP: Int?
    }

    struct Result {
        var outputs: [Output]
        var implementation: String
        var seconds: Double
    }

    let kind: Kind
    let sourceWidth: Int, sourceHeight: Int
    let width: Int, height: Int
    let fps: Int
    private let lock = NSLock()
    private var outputs: [Output] = []
    private var sentAt: [UInt32: UInt64] = [:]
    private var reader = H264SliceQP()

    init(kind: Kind, sourceWidth: Int, sourceHeight: Int, width: Int, height: Int, fps: Int) {
        self.kind = kind
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.width = width
        self.height = height
        self.fps = fps
    }

    func makeEncoder() -> (any RTCVideoEncoder)? {
        let info = ScreenLowLatencyEncoderTests.info("640c34")
        switch kind {
        case .lowLatency: return ScreenLowLatencyEncoder(rateControl: .lowLatency)
        case .lowLatencyQP51: return ScreenLowLatencyEncoder(rateControl: .lowLatencyQP51)
        case .realTime: return ScreenLowLatencyEncoder(rateControl: .realTime)
        // The encoder the stream used before: libwebrtc's, opened at AutoLevel.
        case .webrtc: return RTCDefaultVideoEncoderFactory().createEncoder(ScreenEncoderFactory.encoderInfo(info))
        }
    }

    func run(frames: Int, keyframesAt: Set<Int> = [0], bitrateKbps: UInt32 = 24000) throws -> Result {
        let encoder = try #require(makeEncoder())
        encoder.setCallback { [weak self] image, _ in
            let now = DispatchTime.now().uptimeNanoseconds
            guard let self else { return true }
            let bytes = [UInt8](image.buffer)
            lock.withLock {
                let sent = sentAt[image.timeStamp] ?? now
                outputs.append(Output(rtp: image.timeStamp, bytes: bytes.count, keyframe: image.frameType == .videoFrameKey,
                                      width: image.encodedWidth, height: image.encodedHeight,
                                      nalTypes: Self.nalTypes(bytes), latencyMs: Double(now - sent) / 1e6,
                                      qp: image.qp.intValue, parsedQP: reader.qp(annexB: bytes)))
            }
            return true
        }
        let settings = RTCVideoEncoderSettings()
        settings.name = kRTCVideoCodecH264Name
        settings.width = UInt16(width)
        settings.height = UInt16(height)
        settings.startBitrate = bitrateKbps
        settings.maxBitrate = bitrateKbps
        settings.minBitrate = 300
        settings.maxFramerate = UInt32(fps)
        settings.mode = .screensharing
        #expect(encoder.startEncode(with: settings, numberOfCores: 8) == 0, "the encoder started")
        _ = encoder.setBitrate(bitrateKbps, framerate: UInt32(fps))
        defer { _ = encoder.release() }

        let screen = ScrollingPictures(width: sourceWidth, height: sourceHeight)
        let interval = 1_000_000_000 / UInt64(fps)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0 ..< frames {
            guard let pixels = screen.next() else { continue }
            let at = start + UInt64(index) * interval
            let now = DispatchTime.now().uptimeNanoseconds
            if at > now { usleep(useconds_t((at - now) / 1000)) } // paces the synthetic source at `fps`
            // As libwebrtc's adapter hands it over: the full picture, adapted to the encoder's size.
            let buffer = RTCCVPixelBuffer(pixelBuffer: pixels, adaptedWidth: Int32(width), adaptedHeight: Int32(height),
                                          cropWidth: Int32(sourceWidth), cropHeight: Int32(sourceHeight), cropX: 0, cropY: 0)
            let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
            let rtp = UInt32(index * 90000 / fps + 1)
            frame.timeStamp = Int32(bitPattern: rtp)
            lock.withLock { sentAt[rtp] = DispatchTime.now().uptimeNanoseconds }
            let types: [NSNumber] = [NSNumber(value: (keyframesAt.contains(index) ? RTCFrameType.videoFrameKey : .videoFrameDelta).rawValue)]
            _ = encoder.encode(frame, codecSpecificInfo: nil, frameTypes: types)
        }
        // The last frames' output: at most a second.
        for _ in 0 ..< 100 where lock.withLock({ outputs.count }) < frames { usleep(10000) } // bounded drain of the encoder's queue
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return Result(outputs: lock.withLock { outputs }.sorted { $0.rtp < $1.rtp }, implementation: encoder.implementationName(), seconds: seconds)
    }

    /// The NAL unit types in an Annex B stream, in order.
    static func nalTypes(_ bytes: [UInt8]) -> [UInt8] {
        var types: [UInt8] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                types.append(bytes[index + 3] & 0x1F)
                index += 3
            } else {
                index += 1
            }
        }
        return types
    }
}

/// Scrolling text-like NV12 pictures (``ScrollingScreen``'s texture), one per call.
final class ScrollingPictures {
    let width: Int, height: Int
    private var pool: CVPixelBufferPool?
    private var texture: [UInt8]
    private let rows = 1024
    private var index = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        var generator = SystemRandomNumberGenerator()
        texture = [UInt8](repeating: 235, count: width * rows)
        for line in stride(from: 0, to: rows, by: 24) {
            var x = 8
            while x < width - 16 {
                let glyph = Int.random(in: 6 ... 12, using: &generator)
                let shade = UInt8.random(in: 16 ... 96, using: &generator)
                for y in line + 4 ..< min(line + 18, rows) {
                    for dx in 0 ..< glyph where Int.random(in: 0 ..< 3, using: &generator) > 0 { texture[y * width + x + dx] = shade }
                }
                x += glyph + 2 + (Int.random(in: 0 ..< 6, using: &generator) == 0 ? 8 : 0)
            }
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func next() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let offset = (index * 8) % rows
        index += 1
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            texture.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                for y in 0 ..< height { memcpy(luma + y * stride, base + ((y + offset) % rows) * width, width) }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return buffer
    }
}
#endif
