#if canImport(AVFoundation)
import AVFoundation
import CmuxMobileTransport
import CoreVideo
import Foundation
import Testing
@testable import CmuxMobileLive

/// Measures what `VideoRecompressor.prepared` does to a 1-minute 4K30 clip: the same
/// `AVAssetExportSession` with `AVAssetExportPresetHEVC1920x1080`, `shouldOptimizeForNetworkUse`,
/// `.mov`, `export(to:as:)`. It prints one `VIDEO_RECOMPRESS_MEASURE` line and attaches it as
/// `video-recompress-measure.txt`. Replaces the modeled "62 MB out of 170 MB in".
///
/// It runs only with CMUX_TICK_HARNESS=1, the opt-in scripts/ci/cmux-next-ios-sim.sh already sets
/// when its `only=` filter names TickHarnessCellsTests (no script change needed). It does not run
/// in the kit's full run: it writes about 170 MB and exports for tens of seconds.
///
/// Source: CMUX_VIDEO_SOURCE_URL (a local file path) when set, trimmed to 60 s; else a synthetic
/// HEVC 3840x2160 30 fps clip at 22.7 Mbit/s written by AVAssetWriter (a textured scene that pans,
/// plus fresh noise blocks every frame, so it does not compress trivially). The line says which.
@Suite(.serialized, .enabled(if: ["CMUX_VIDEO_RECOMPRESS_MEASURE", "CMUX_TICK_HARNESS"].contains {
    ProcessInfo.processInfo.environment[$0] == "1"
}, "runs alone: CMUX_TICK_HARNESS=1"))
struct VideoRecompressMeasureTests {
    static let width = 3840
    static let height = 2160
    static let fps = 30
    static let seconds = 60
    static let bitRate = 22_700_000

    @Test func oneMinute4KExportToHEVC1080() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-video-measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (source, kind) = try await SharedClip.shared.clip()
        // Read the source back: its own size, duration and bytes.
        let inBytes = try Self.bytes(source)
        let probe = AVURLAsset(url: source)
        let probeDuration = try await probe.load(.duration).seconds
        let track = try #require(try await probe.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        #expect(Int(natural.width) == Self.width && Int(natural.height) == Self.height)
        #expect(abs(probeDuration - Double(Self.seconds)) < 0.5)

        // The export, as VideoRecompressor does it. Timed from the asset's creation, like its `started`.
        let out = dir.appendingPathComponent("out.mov")
        let started = ContinuousClock.now
        let asset = AVURLAsset(url: source)
        _ = try await asset.load(.duration)
        let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080))
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: out, as: .mov)
        let elapsed = ContinuousClock.now - started
        let exportMs = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        let outBytes = try Self.bytes(out)
        let outAsset = AVURLAsset(url: out)
        let outTrack = try #require(try await outAsset.loadTracks(withMediaType: .video).first)
        let outSize = try await outTrack.load(.naturalSize)
        let line = "VIDEO_RECOMPRESS_MEASURE source=\(kind) in_bytes=\(inBytes) out_bytes=\(outBytes) "
            + "export_ms=\(exportMs) width=\(Int(outSize.width)) height=\(Int(outSize.height)) "
            + "duration_ms=\(Int((probeDuration * 1000).rounded())) device=\(Self.device)"
        print(line)
        Attachment.record(line + "\n", named: "video-recompress-measure.txt")
        #expect(outBytes > 0)
        #expect(Int(outSize.width) == 1920 && Int(outSize.height) == 1080)
    }

    #if os(iOS)
    /// Cancels `VideoRecompressor.prepared` once its progress passes 5%: it must throw
    /// CancellationError within a few seconds and leave no cmux-recompressed-videos/<uuid> folder.
    @Test func cancelMidExportStopsAndCleansUp() async throws {
        let (clip, _) = try await SharedClip.shared.clip()
        let key = VideoRecompressor.settingKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-recompressed-videos", isDirectory: true)
        func folders() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        }
        let before = folders()
        let state = CancelState()
        let task = Task {
            try await VideoRecompressor.prepared(.file(clip), name: "clip.mov", report: { fraction in
                if fraction > 0.05 { await state.sawFraction(fraction) }
            })
        }
        await state.attach(task)
        // The task is cancelled from inside the report path; wait for its end.
        var threw = false
        do { _ = try await task.value } catch is CancellationError { threw = true }
        let end = ContinuousClock.now
        let cancelledAt = await state.cancelledAt
        let fraction = await state.fraction
        let cancelled = try #require(cancelledAt, "progress never passed 0.05, so nothing was cancelled")
        let stop = end - cancelled
        let ms = Int(stop.components.seconds) * 1000 + Int(stop.components.attoseconds / 1_000_000_000_000_000)
        let line = "VIDEO_RECOMPRESS_CANCEL fraction_at_cancel=\(fraction) ms_to_stop=\(ms)"
        print(line)
        Attachment.record(line + "\n", named: "video-recompress-cancel.txt")
        #expect(threw, "prepared must throw CancellationError")
        #expect(ms < 5000)
        #expect(folders().subtracting(before).isEmpty, "a recompressed-videos folder was left behind")
    }
    #endif

    static var device: String {
        #if targetEnvironment(simulator)
        return "sim-\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown")"
        #elseif os(macOS)
        return "mac"
        #else
        return "device"
        #endif
    }

    static func bytes(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// The first 60 s of `input`, passed through at its own quality into a .mov.
    static func trimmed(_ input: URL, to output: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough))
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 600))
        try await session.export(to: output, as: .mov)
        return output
    }

    /// 60 s of 3840x2160 30 fps HEVC at ~22.7 Mbit/s. A noisy texture twice the frame wide pans
    /// 3 px per frame (a copy per row, so it is cheap in a debug build), and 24 blocks of fresh
    /// noise land on every frame.
    static func synthesize(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // The scene: 2x frame width, a smooth gradient with low-amplitude noise on top.
        let sceneW = width * 2
        var scene = [UInt32](repeating: 0, count: sceneW * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        scene.withUnsafeMutableBufferPointer { px in
            for y in 0..<height {
                for x in 0..<sceneW {
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    let n = UInt32(truncatingIfNeeded: state) & 0x0F
                    let r = UInt32((x / 24) & 0xFF) &+ n
                    let g = UInt32((y / 9) & 0xFF) &+ (n >> 1)
                    let b = UInt32(((x + y) / 31) & 0xFF) &+ n
                    px[y * sceneW + x] = 0xFF00_0000 | (min(r, 255) << 16) | (min(g, 255) << 8) | min(b, 255)
                }
            }
        }

        let frames = seconds * fps
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { Issue.record("no pixel buffer pool"); return }
            var maybe: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe)
            let buffer = try #require(maybe)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let panX = (i * 3) % width
            scene.withUnsafeBufferPointer { px in
                for y in 0..<height {
                    memcpy(base + y * stride, px.baseAddress! + y * sceneW + panX, width * 4)
                }
            }
            for _ in 0..<24 {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let bx = Int(state % UInt64(width - 64)), by = Int((state >> 20) % UInt64(height - 64))
                for row in 0..<64 {
                    let p = (base + (by + row) * stride + bx * 4).assumingMemoryBound(to: UInt32.self)
                    for col in 0..<64 {
                        state ^= state << 13; state ^= state >> 7; state ^= state << 17
                        p[col] = 0xFF00_0000 | UInt32(truncatingIfNeeded: state) & 0x00FF_FFFF
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "writer: \(String(describing: writer.error))")
    }
}

#if os(iOS)
private actor CancelState {
    var fraction = 0.0
    var cancelledAt: ContinuousClock.Instant?
    private var task: Task<(payload: LinkUpload.Payload, name: String, exported: Bool), Error>?
    func attach(_ t: Task<(payload: LinkUpload.Payload, name: String, exported: Bool), Error>) {
        task = t
        if cancelledAt != nil { t.cancel() }
    }
    func sawFraction(_ f: Double) {
        guard cancelledAt == nil else { return }
        fraction = f
        cancelledAt = .now
        task?.cancel()
    }
}
#endif

/// The source clip, made once and shared by this file's tests.
private actor SharedClip {
    static let shared = SharedClip()
    private var made: (URL, String)?

    func clip() async throws -> (URL, String) {
        if let made { return made }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-video-measure-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("source.mov")
        let result: (URL, String)
        if let path = ProcessInfo.processInfo.environment["CMUX_VIDEO_SOURCE_URL"], !path.isEmpty {
            result = (try await VideoRecompressMeasureTests.trimmed(URL(fileURLWithPath: path), to: url), "real")
        } else {
            try await VideoRecompressMeasureTests.synthesize(to: url)
            result = (url, "synthetic")
        }
        made = result
        return result
    }
}
#endif
