import AVFoundation
import CmuxNextCompat
import CoreMedia
public import Foundation

/// A viewer stream with no peer (goal screen-share-viewer-present): replays a recorded screen
/// share, such as an MP4 the viewer's Record button wrote or any H.264 or HEVC movie, as access
/// units at the file's own pace. The units go through the same `RemoteDecodePipeline` and
/// presenter as a live session, so the viewer's Decode and Present stages can be read without a
/// host, a network or a second Mac.
///
/// Each loop of the file starts on its first keyframe and keeps the frame numbers consecutive,
/// so the pipeline sees one unbroken stream. A replay has nobody to ask for an IDR:
/// after a decode error, the picture resumes at the next keyframe in the file.
public nonisolated final class RemoteMovieReplaySource: RemoteViewStreamSource {
    public nonisolated enum ReplayError: Error, Equatable {
        case noVideoTrack
        /// The track is not H.264 or HEVC (its four-character code).
        case unsupportedCodec(String)
        case unreadable(String)
        /// The file has no keyframe to start a decode from.
        case noKeyframe
    }

    /// One access unit of the file: Annex-B bytes, and its time from the file's first frame.
    public nonisolated struct Sample: Sendable, Equatable {
        public var data: Data
        public var keyframe: Bool
        public var seconds: Double

        public init(data: Data, keyframe: Bool, seconds: Double) {
            self.data = data
            self.keyframe = keyframe
            self.seconds = seconds
        }
    }

    public let codec: RemoteVideoCodec
    public let samples: [Sample]
    public let width: Int
    public let height: Int
    /// How many times `accessUnits()` plays the file before it finishes.
    public let loops: Int
    /// Playback speed: 1 is the file's own pace (tests replay faster).
    public let rate: Double
    private let state = Mutex(State())

    private struct State {
        var units: AsyncStream<RemoteAccessUnit>.Continuation?
        var task: Task<Void, Never>?
        var statuses: AsyncStream<RemoteViewStatus>.Continuation?
        var cursors: AsyncStream<RemoteCursorState>.Continuation?
        var keyframeRequests = 0
    }

    public init(codec: RemoteVideoCodec, samples: [Sample], width: Int, height: Int, loops: Int = 1,
                rate: Double = 1) throws(ReplayError) {
        // A decode starts at a keyframe: drop anything before the first one.
        guard let first = samples.firstIndex(where: \.keyframe) else { throw .noKeyframe }
        let base = samples[first].seconds
        self.samples = samples[first...].map { Sample(data: $0.data, keyframe: $0.keyframe, seconds: $0.seconds - base) }
        self.codec = codec
        self.width = width
        self.height = height
        self.loops = max(1, loops)
        self.rate = rate > 0 ? rate : 1
    }

    /// Reads every video sample of the movie at `url` into memory: a recording of a few seconds
    /// to a few minutes.
    public static func load(_ url: URL, loops: Int = 1, rate: Double = 1) async throws -> RemoteMovieReplaySource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReplayError.noVideoTrack }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw ReplayError.noVideoTrack }
        let codec: RemoteVideoCodec
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_H264: codec = .h264
        case kCMVideoCodecType_HEVC: codec = .hevc
        case let other: throw ReplayError.unsupportedCodec(fourCC(other))
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ReplayError.unreadable(error.localizedDescription)
        }
        // No output settings: the compressed samples as the file holds them, no re-encoding.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw ReplayError.unreadable(reader.error?.localizedDescription ?? "the reader did not start")
        }
        var samples: [Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            let keyframe = SyntheticFrameEncoder.isKeyframe(buffer)
            guard let data = SyntheticFrameEncoder.annexB(buffer, keyframe: keyframe, codec: codec) else { continue }
            // Decode order is the order to send; a screen share has no B-frames, so its times rise.
            let decodeTime = CMSampleBufferGetDecodeTimeStamp(buffer)
            let time = decodeTime.isValid ? decodeTime : CMSampleBufferGetPresentationTimeStamp(buffer)
            samples.append(Sample(data: data, keyframe: keyframe, seconds: time.isValid ? time.seconds : 0))
        }
        if reader.status == .failed {
            throw ReplayError.unreadable(reader.error?.localizedDescription ?? "the read failed")
        }
        return try RemoteMovieReplaySource(codec: codec, samples: samples, width: Int(size.width),
                                           height: Int(size.height), loops: loops, rate: rate)
    }

    /// The file's length, one frame interval after its last frame: where the next loop starts.
    public var period: Double {
        guard let last = samples.last else { return 0 }
        let interval = samples.count > 1 ? last.seconds / Double(samples.count - 1) : 1.0 / 60
        return last.seconds + interval
    }

    /// Starts the replay from the beginning; a second call ends the first replay.
    public func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
        let samples = samples, codec = codec, loops = loops, rate = rate, period = period
        // task-owner: this replay; ends with its last loop, the stream's consumer, or the next replay
        let task = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            var frame: UInt32 = 0
            replay: for loop in 0 ..< loops {
                for sample in samples {
                    let due = start + .seconds((Double(loop) * period + sample.seconds) / rate)
                    if due > clock.now { try? await clock.sleep(until: due) }
                    if Task.isCancelled { break replay }
                    let now = DispatchTime.now().uptimeNanoseconds
                    continuation.yield(RemoteAccessUnit(
                        frame: frame, flags: sample.keyframe ? .keyframe : [], tCaptureMicros: now / 1_000,
                        data: sample.data, codec: codec, releasedAtNanos: now))
                    frame &+= 1
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        let previous = state.withLock { state in
            defer {
                state.units = continuation
                state.task = task
            }
            return (state.units, state.task)
        }
        previous.1?.cancel()
        previous.0?.finish()
        return stream
    }

    public func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(4))
        let previous = state.withLock { state in
            defer { state.statuses = continuation }
            return state.statuses
        }
        previous?.finish()
        continuation.yield(RemoteViewStatus(path: .direct, rttMs: 0, state: .streaming,
                                            streamWidth: width, streamHeight: height))
        return stream
    }

    public func cursorUpdates() -> AsyncStream<RemoteCursorState> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteCursorState.self, bufferingPolicy: .bufferingNewest(1))
        let previous = state.withLock { state in
            defer { state.cursors = continuation }
            return state.cursors
        }
        previous?.finish()
        return stream
    }

    /// Counted only: the file has no host to make a new keyframe; the next one in it resumes the picture.
    public func requestKeyframe() {
        state.withLock { $0.keyframeRequests += 1 }
    }

    public var keyframeRequests: Int { state.withLock { $0.keyframeRequests } }

    /// Ends the replay: every stream finishes.
    public func stop() {
        let (units, task, statuses, cursors) = state.withLock { ($0.units, $0.task, $0.statuses, $0.cursors) }
        task?.cancel()
        units?.finish()
        statuses?.finish()
        cursors?.finish()
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }
}
