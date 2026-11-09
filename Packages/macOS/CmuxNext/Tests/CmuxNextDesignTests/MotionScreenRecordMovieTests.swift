#if DEBUG || CMUX_BENCH_HOOKS
import AVFoundation
@testable import CmuxNextDesign
import CoreMedia
import CoreVideo
import Foundation
import Testing

/// cmux-ad m29 item 3 (2026-11-05): 20 `debug.motion record_*` films of the resize-videos gallery have no moov atom
/// (ftyp, wide, an mdat of size 0, then megabytes of frames). In 18 a journey step failed between `record_start` and
/// `record_stop`, the kit fetched the movie while the app still wrote it, and the lease then ended the app; in 2 the
/// app stopped answering mid-film. The recorder wrote a QuickTime movie whose index only `finishWriting` writes, so a
/// movie that is not stopped has no frame any reader can open. A recording cut off at any moment must play up to its
/// last fragment.
nonisolated struct MotionScreenRecordMovieTests {
    typealias Movie = (writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor)

    static let width = 320
    static let height = 240
    /// Two seconds of frames at the recorder's 120 Hz.
    static let frames = 240

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("motion-record-movie-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A BGRA frame on an IOSurface, as ScreenCaptureKit gives them, of one gray level.
    static func frame(level: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        let made = try #require(status == kCVReturnSuccess ? buffer : nil, "CVPixelBufferCreate: \(status)")
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        if let base = CVPixelBufferGetBaseAddress(made) {
            memset(base, Int32(level), CVPixelBufferGetBytesPerRow(made) * height)
        }
        return made
    }

    /// `frames` frames at 1/120 s steps from time zero, each appended once the encoder takes more (the recorder's own
    /// frames come from ScreenCaptureKit at the display's rate). Returns how many were appended.
    static func append(_ movie: Movie, frames: Int) async throws -> Int {
        var appended = 0
        for index in 0..<frames {
            let ready = ContinuousClock.now + .seconds(5)
            while !movie.input.isReadyForMoreMediaData, ContinuousClock.now < ready {
                try await Task.sleep(for: .milliseconds(1))
            }
            let time = CMTime(value: CMTimeValue(index), timescale: 120)
            if movie.adaptor.append(try frame(level: UInt8(truncatingIfNeeded: index * 7)), withPresentationTime: time) {
                appended += 1
            }
        }
        return appended
    }

    /// The video track of the movie at `url` as a reader sees it: its duration in seconds and its frame count.
    static func read(_ url: URL) async throws -> (seconds: Double, frames: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return (0, 0) }
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return (range.duration.seconds, 0) }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return (range.duration.seconds, count)
    }

    @Test func aRecordingCutOffBeforeItsStopStillPlays() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cut-off.mov")
        let movie = try ScreenRecording.movieWriter(url: url, width: Self.width, height: Self.height, prores: false,
                                                    bitsPerSecond: 20_000_000)
        defer { if movie.writer.status == .writing { movie.writer.cancelWriting() } }
        let appended = try await Self.append(movie, frames: Self.frames)
        #expect(appended == Self.frames)

        // Never stopped: no markAsFinished, no finishWriting. A copy of the bytes on disk is what the kit's fetch took
        // from a film whose step failed, and what a quit or a crash leaves. The writer keeps its own pace, so the copy
        // is taken again until it reads or 15 s pass.
        let deadline = ContinuousClock.now + .seconds(15)
        var seen: (seconds: Double, frames: Int) = (0, 0)
        var failure = "none"
        repeat {
            let copy = folder.appendingPathComponent("copy-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: url, to: copy)
            do {
                seen = try await Self.read(copy)
            } catch {
                failure = "\(error)"
            }
            if seen.seconds > 0, seen.frames > 0 { break }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < deadline
        #expect(seen.seconds > 0, "a copy of a movie cut off after 2 s has no video track a reader opens (last error: \(failure))")
        #expect(seen.frames > 0, "a copy of a movie cut off after 2 s has no frame (last error: \(failure))")
    }

    @Test func aStoppedRecordingKeepsEveryFrame() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stopped.mov")
        let movie = try ScreenRecording.movieWriter(url: url, width: Self.width, height: Self.height, prores: false,
                                                    bitsPerSecond: 20_000_000)
        let appended = try await Self.append(movie, frames: Self.frames)
        #expect(appended == Self.frames)
        // record_stop's close(): the input ends, then the writer finishes.
        movie.input.markAsFinished()
        await movie.writer.finishWriting()
        #expect(movie.writer.status == .completed, "finishWriting: \(String(describing: movie.writer.error))")
        let seen = try await Self.read(url)
        #expect(seen.frames == Self.frames)
        #expect(abs(seen.seconds - Double(Self.frames) / 120) < 0.02, "duration \(seen.seconds) s")
    }
}
#endif
