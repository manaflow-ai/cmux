import CmuxFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum WindowRecordingSessionError: Error, LocalizedError {
    case unsupportedSystem
    case windowGone
    case captureTimedOut
    case captureFailed(String)
    case composeFailed
    case alreadyFinished
    case outputNotAFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            "recording a cmux window needs macOS 14.4 or later"
        case .windowGone:
            "the window is no longer available"
        case .captureTimedOut:
            "window capture timed out"
        case let .captureFailed(detail):
            "window capture failed: \(detail)"
        case .composeFailed:
            "a frame could not be composed"
        case .alreadyFinished:
            "the recording has already finished"
        case let .outputNotAFile(path):
            "\(path) is not a file the recording may replace"
        }
    }
}

extension WindowRecordingSessionError {
    /// Keeps the recorder's wording for a failure raised by the shared capture.
    init(_ failure: OwnWindowFrameCapture.Failure) {
        switch failure {
        case .unsupportedSystem:
            self = .unsupportedSystem
        case .windowGone:
            self = .windowGone
        case .timedOut:
            self = .captureTimedOut
        case let .captureFailed(detail):
            self = .captureFailed(detail)
        }
    }
}

/// What `window.record.start`, `.status` and `.stop` report back.
struct WindowRecordingStatus: Sendable {
    enum State: String, Sendable {
        case recording
        case finished
        case failed
    }

    let id: String
    let state: State
    let format: WindowRecordingRequest.Format
    let path: String
    let label: String
    let frames: Int
    let seconds: Double
    let width: Int
    let height: Int
    let notes: Int
    let requestedFramesPerSecond: Int
    let maximumSeconds: Double
    let error: String?

    var jsonObject: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "state": state.rawValue,
            "format": format.rawValue,
            "path": path,
            "frames": frames,
            "seconds": (seconds * 1000).rounded() / 1000,
            "width": width,
            "height": height,
            "notes": notes,
            "fps_requested": requestedFramesPerSecond,
            "max_seconds": maximumSeconds,
        ]
        if !label.isEmpty {
            payload["label"] = label
        }
        // What the sampler actually managed. A clip whose effective rate is far
        // below the requested one still plays at the right speed, because frames
        // are timed by when they were captured.
        if frames > 1, seconds > 0 {
            payload["fps_effective"] = ((Double(frames - 1) / seconds) * 10).rounded() / 10
        }
        if let error {
            payload["error"] = error
        }
        return payload
    }
}

/// One in-flight recording of one of cmux's own windows.
///
/// Frames are sampled with ScreenCaptureKit's screenshot API on a schedule
/// instead of through a live `SCStream`: the same permission-free own-process
/// path the window screenshot command already uses, and no queue of
/// full-resolution frames waiting in memory.
actor WindowRecordingSession {
    let id: String
    let request: WindowRecordingRequest
    let outputURL: URL
    let windowHandle: String?

    private let capture: OwnWindowFrameCapture
    /// Frames go here while the clip runs; `outputURL` only appears once the
    /// clip closes cleanly. A failed, interrupted or killed recording therefore
    /// never leaves a broken file where the caller asked for the clip, and an
    /// existing file there survives until there is something to replace it with.
    private let workingURL: URL
    private var filter: SCContentFilter?
    private var writer: WindowRecordingFrameWriter?
    private var geometry: WindowRecordingFrameGeometry?
    private var captions: WindowRecordingCaptionTrack
    private var state: WindowRecordingStatus.State = .recording
    private var failure: String?
    private var frames = 0
    private var startUptime = ProcessInfo.processInfo.systemUptime
    private var lastOffsetSeconds: Double = 0
    private var loop: Task<Void, Never>?
    // Appends and the final close must not interleave: this actor suspends
    // inside every append, so a `stop` arriving mid-append would otherwise
    // close the file underneath it, and AVFoundation answers a frame appended
    // after that with an exception no caller can catch.
    private var writerBusy = false
    private var writerWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        id: String,
        request: WindowRecordingRequest,
        outputURL: URL,
        windowID: CGWindowID,
        windowHandle: String?
    ) {
        self.id = id
        self.request = request
        self.outputURL = outputURL
        capture = OwnWindowFrameCapture(windowID: windowID)
        self.windowHandle = windowHandle
        workingURL = Self.workingURL(for: outputURL, id: id)
        captions = WindowRecordingCaptionTrack()
    }

    private static func workingURL(for outputURL: URL, id: String) -> URL {
        WindowCaptureOutputFile.workingURL(for: outputURL, discriminator: "recording-\(id)")
    }

    var isRecording: Bool {
        state == .recording
    }

    var status: WindowRecordingStatus {
        WindowRecordingStatus(
            id: id,
            state: state,
            format: request.format,
            path: outputURL.path,
            label: request.label,
            frames: frames,
            seconds: lastOffsetSeconds,
            width: geometry?.outputWidth ?? 0,
            height: geometry?.outputHeight ?? 0,
            notes: captions.count,
            requestedFramesPerSecond: request.framesPerSecond,
            maximumSeconds: request.maximumSeconds,
            error: failure
        )
    }

    /// Opens the output and captures the first frame, so a caller that cannot
    /// record at all learns about it from `record start` rather than from an
    /// empty file later.
    func start() async throws {
        filter = try await resolveFilter()
        // `abandon` can run while filter resolution is suspended. Do not start
        // another ScreenCaptureKit operation after that authoritative stop.
        guard state == .recording else {
            throw WindowRecordingSessionError.alreadyFinished
        }
        let sample = try await sample()
        let planned = try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: sample.image.width,
            windowPixelHeight: sample.image.height,
            pointPixelScale: sample.pointPixelScale,
            request: request
        )
        geometry = planned
        // A caller that gave up on this start (see `abandon`) may have ended
        // the session while the capture above was in flight; open nothing then.
        guard state == .recording else {
            throw WindowRecordingSessionError.alreadyFinished
        }
        writer = try makeWriter(geometry: planned)
        startUptime = ProcessInfo.processInfo.systemUptime
        do {
            try await write(sample: sample, offsetSeconds: 0)
        } catch {
            // A first frame that cannot be written leaves an open writer and a
            // partial file behind; close and discard both before giving up.
            await fail(error)
            throw error
        }
        guard state == .recording else {
            throw WindowRecordingSessionError.alreadyFinished
        }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    /// Adds a caption at the current point in the clip.
    func note(_ text: String) -> Bool {
        guard state == .recording else { return false }
        return captions.append(
            text: text,
            atOffsetSeconds: ProcessInfo.processInfo.systemUptime - startUptime
        )
    }

    /// Ends the recording and closes the file. Idempotent: an agent may stop a
    /// clip that already reached its own limit.
    func stop() async -> WindowRecordingStatus {
        loop?.cancel()
        loop = nil
        if state == .recording {
            await finalize()
        }
        return status
    }

    /// Ends the session and throws away whatever it captured. Used when the
    /// `record start` that opened it already reported a timeout: the caller
    /// believes nothing is recording, so nothing may be left recording or on
    /// disk. Idempotent, and safe while `start` is still suspended.
    func abandon(reason: String) async {
        await acquireWriter()
        defer { releaseWriter() }
        // Cancelled after the writer turn, not before: a `start` that was
        // mid-append when this was called creates its sample loop only once
        // that append returns.
        loop?.cancel()
        loop = nil
        await discardWriter()
        guard state == .recording else { return }
        state = .failed
        failure = reason
    }

    private func run() async {
        let interval = request.frameInterval
        let endUptime = startUptime + request.maximumSeconds
        var schedule = WindowRecordingSampleSchedule(
            firstTargetUptime: startUptime + interval,
            interval: interval
        )
        while !Task.isCancelled, state == .recording {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < endUptime else {
                await finalize()
                return
            }
            let wakeUptime = min(schedule.target(atOrAfter: now), endUptime)
            if wakeUptime > now {
                try? await Task.sleep(
                    nanoseconds: UInt64((wakeUptime - now) * 1_000_000_000)
                )
            }
            guard !Task.isCancelled, state == .recording else { return }
            let offset = ProcessInfo.processInfo.systemUptime - startUptime
            if offset >= request.maximumSeconds || frames >= request.frameBudget {
                await finalize()
                return
            }
            // Advance by the wall-clock slot before sampling. If capture or
            // encoding runs long, the next loop skips every elapsed slot and
            // waits for a future one instead of spinning to catch up based on
            // the number of frames that happened to succeed.
            schedule.advanceOneSlot()
            do {
                try await write(sample: try await sample(), offsetSeconds: offset)
            } catch {
                await fail(error)
                return
            }
            if frames >= request.frameBudget {
                await finalize()
                return
            }
        }
    }

    private func write(sample: Sample, offsetSeconds: Double) async throws {
        await acquireWriter()
        defer { releaseWriter() }
        guard state == .recording, let writer, let geometry else {
            throw WindowRecordingSessionError.alreadyFinished
        }
        // A window resized mid-clip is re-cropped into the frame size the clip
        // opened with, rather than ending the recording, so only the crop is
        // replanned here. The exception is a `region` the window has shrunk out
        // of: planning throws, the caller gets state `failed` with the frames
        // captured so far, because there is no rectangle left to sample.
        let planned = try WindowRecordingFrameGeometry.planCrop(
            windowPixelWidth: sample.image.width,
            windowPixelHeight: sample.image.height,
            pointPixelScale: sample.pointPixelScale,
            request: request
        )
        let composed = WindowRecordingFrameComposer.compose(
            source: sample.image,
            geometry: geometry.adoptingCrop(of: planned),
            caption: request.drawsCaptions ? captions.caption(atOffsetSeconds: offsetSeconds) : nil
        )
        guard let composed else { throw WindowRecordingSessionError.composeFailed }
        try await writer.append(composed, atOffsetSeconds: offsetSeconds)
        frames += 1
        lastOffsetSeconds = offsetSeconds
    }

    private func finalize() async {
        await acquireWriter()
        defer { releaseWriter() }
        guard state == .recording else { return }
        guard let writer else {
            state = .failed
            failure = WindowRecordingSessionError.alreadyFinished.localizedDescription
            return
        }
        self.writer = nil
        do {
            try await writer.finish()
            try promote()
            state = .finished
        } catch {
            state = .failed
            failure = error.localizedDescription
            try? FileManager.default.removeItem(at: workingURL)
        }
    }

    private func fail(_ error: Error) async {
        await acquireWriter()
        defer { releaseWriter() }
        // A clip that already closed keeps its own verdict: a stop racing a
        // capture failure must not turn a finished clip into a failed one. A
        // writer opened by a `start` that lost that race is still released.
        guard state == .recording else {
            await discardWriter()
            return
        }
        // Keep whatever was captured before the failure: a clip that ends when
        // the window closes is still evidence of what happened before that.
        if let writer {
            self.writer = nil
            do {
                // Close the writer even with no frames, so an append that
                // started it and then failed does not leave it open.
                try await writer.finish()
                if frames > 0 {
                    try promote()
                }
            } catch {
                // Nothing usable was written; the partial file goes away below.
            }
        }
        try? FileManager.default.removeItem(at: workingURL)
        state = .failed
        failure = error.localizedDescription
    }

    /// Drops an open writer and its partial file without promoting anything.
    /// The writer is closed first so no handle outlives the file it points at.
    private func discardWriter() async {
        guard let writer else { return }
        self.writer = nil
        try? await writer.finish()
        try? FileManager.default.removeItem(at: workingURL)
    }

    /// Moves the finished clip to the path the caller asked for.
    private func promote() throws {
        try WindowCaptureOutputFile.promote(from: workingURL, to: outputURL)
    }

    /// Only one operation touches the writer at a time. An actor alone is not
    /// enough: every append suspends this actor, which lets `stop` in.
    private func acquireWriter() async {
        while writerBusy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writerWaiters.append(continuation)
            }
        }
        writerBusy = true
    }

    private func releaseWriter() {
        writerBusy = false
        guard !writerWaiters.isEmpty else { return }
        writerWaiters.removeFirst().resume()
    }

    private func makeWriter(
        geometry: WindowRecordingFrameGeometry
    ) throws -> WindowRecordingFrameWriter {
        guard WindowCaptureOutputFile.isReplaceable(at: outputURL) else {
            throw WindowRecordingSessionError.outputNotAFile(outputURL.path)
        }
        try WindowCaptureOutputFile.prepare(outputURL: outputURL, workingURL: workingURL)
        switch request.format {
        case .mp4:
            return try WindowRecordingMP4Writer(
                url: workingURL,
                width: geometry.outputWidth,
                height: geometry.outputHeight,
                framesPerSecond: request.framesPerSecond
            )
        case .gif:
            return try WindowRecordingGIFWriter(
                url: workingURL,
                framesPerSecond: request.framesPerSecond
            )
        }
    }

    /// The recorder's name for a captured frame, unchanged from when it owned
    /// the capture itself.
    private typealias Sample = OwnWindowFrame

    private func resolveFilter() async throws -> SCContentFilter {
        try await translatingCaptureFailure { try await capture.resolveFilter() }
    }

    private func sample() async throws -> Sample {
        guard let filter else { throw WindowRecordingSessionError.windowGone }
        return try await translatingCaptureFailure {
            try await OwnWindowFrameCapture.sample(filter: filter)
        }
    }

    /// Every error a caller sees from a recording is a `WindowRecordingSessionError`,
    /// including the ones the shared capture raises.
    private func translatingCaptureFailure<T>(
        _ work: () async throws -> T
    ) async throws -> T {
        do {
            return try await work()
        } catch let failure as OwnWindowFrameCapture.Failure {
            throw WindowRecordingSessionError(failure)
        }
    }
}
