#if os(iOS)
import AVFoundation
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileTerminal

@Suite(.serialized) struct VideoCompressorScopeTests {
    /// Makes a real movie visible at the picked URL only while its scope is open.
    private struct MovieScope: SecurityScope {
        let movie: URL
        var cancelWhenOpened = false

        func startAccessing(_ url: URL) -> Bool {
            do {
                try FileManager.default.linkItem(at: movie, to: url)
                if cancelWhenOpened { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            } catch {
                Issue.record("Could not expose the movie at the picked URL: \(error)")
                return false
            }
        }

        func stopAccessing(_ url: URL) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Issue.record("Could not release the picked URL: \(error)")
            }
        }
    }

    @Test func malformedMetadataFallsBackToOriginal() {
        let size = CGSize(width: 1920, height: 1080)
        for duration: CMTime in [.indefinite, .invalid, .positiveInfinity, .negativeInfinity,
                                 CMTime(value: .max, timescale: 1), CMTime(value: -1, timescale: 1)] {
            #expect(VideoCompressor.plan(displaySize: size, duration: duration, bytes: 100, codec: "h264") == nil)
        }
        let duration = CMTime(value: 1, timescale: 3)
        for dimension: CGFloat in [.nan, .infinity, 0, CGFloat(UInt32.max) + 1] {
            for invalid in [CGSize(width: dimension, height: 1), CGSize(width: 1, height: dimension)] {
                #expect(VideoCompressor.plan(displaySize: invalid, duration: duration, bytes: 100, codec: "h264") == nil)
            }
        }
        let rotated = CGSize(width: -1079.75, height: 1919.75)
        let plan = VideoCompressor.plan(displaySize: rotated, duration: duration, bytes: 100, codec: "h264")
        #expect(plan?.maxLongSide == 1920)
    }

    @Test func largePlayableMovieProducesSmallerPlayableExport() async throws {
        let fixture = try await MockArtifactSource.recordingURL()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        // A valid MP4 free-space box puts the real H.264 recording over the original-size threshold.
        let boxSize: UInt32 = 26 * 1024 * 1024
        let file = try FileHandle(forWritingTo: source)
        do {
            let end = try file.seekToEnd()
            var length = boxSize.bigEndian
            try withUnsafeBytes(of: &length) { try file.write(contentsOf: Data($0)) }
            try file.write(contentsOf: Data("free".utf8))
            try file.truncate(atOffset: end + UInt64(boxSize))
            try file.close()
        } catch {
            try? file.close()
            throw error
        }

        let prepared = await VideoCompressor.prepare(ScopedFile(source)) { _ in }
        #expect(prepared.plan?.reencode == true)
        let output = try #require(prepared.output)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let sourceBytes = try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let outputBytes = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(outputBytes > 0 && outputBytes < sourceBytes)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC })
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
    }

    @Test func filePickerMovieCanBeInspectedAndAccessIsReleasedOnReturnOrCancellation() async throws {
        let movie = try await MockArtifactSource.recordingURL()
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        for cancel in [false, true] {
            let file = ScopedFile(picked, scope: MovieScope(movie: movie, cancelWhenOpened: cancel))
            let result = await Task { await VideoCompressor.prepare(file) { _ in } }.value
            if cancel {
                #expect(result.plan == nil)
            } else {
                // A plan means AVFoundation actually read the track and its duration.
                #expect(result.plan?.reencode == false)
            }
            #expect(result.output == nil)
            #expect(!FileManager.default.fileExists(atPath: picked.path))
        }
    }
}
#endif
