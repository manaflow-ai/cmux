import CmuxFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum WindowRecordingSessionError: Error, LocalizedError {
    case unsupportedSystem
    case windowGone
    case captureFailed(String)
    case composeFailed
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            "recording a cmux window needs macOS 14.4 or later"
        case .windowGone:
            "the window is no longer available"
        case let .captureFailed(detail):
            "window capture failed: \(detail)"
        case .composeFailed:
            "a frame could not be composed"
        case .alreadyFinished:
            "the recording has already finished"
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

    private let windowID: CGWindowID
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
        self.windowID = windowID
        self.windowHandle = windowHandle
        captions = WindowRecordingCaptionTrack()
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
        let sample = try await sample()
        let planned = try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: sample.image.width,
            windowPixelHeight: sample.image.height,
            pointPixelScale: sample.pointPixelScale,
            request: request
        )
        geometry = planned
        writer = try makeWriter(geometry: planned)
        startUptime = ProcessInfo.processInfo.systemUptime
        try await write(sample: sample, offsetSeconds: 0)
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

    private func run() async {
        while !Task.isCancelled, state == .recording {
            let target = startUptime + (Double(frames) * request.frameInterval)
            let now = ProcessInfo.processInfo.systemUptime
            if target > now {
                try? await Task.sleep(nanoseconds: UInt64((target - now) * 1_000_000_000))
            }
            guard !Task.isCancelled, state == .recording else { return }
            let offset = ProcessInfo.processInfo.systemUptime - startUptime
            if offset >= request.maximumSeconds || frames >= request.frameBudget {
                await finalize()
                return
            }
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
        guard let writer, let geometry else { throw WindowRecordingSessionError.alreadyFinished }
        // A window resized mid-clip is re-cropped into the frame size the clip
        // opened with, rather than ending the recording.
        let planned = try WindowRecordingFrameGeometry.plan(
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
        guard state == .recording else { return }
        guard let writer else {
            state = .failed
            failure = WindowRecordingSessionError.alreadyFinished.localizedDescription
            return
        }
        self.writer = nil
        do {
            try await writer.finish()
            state = .finished
        } catch {
            state = .failed
            failure = error.localizedDescription
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func fail(_ error: Error) async {
        // Keep whatever was captured before the failure: a clip that ends when
        // the window closes is still evidence of what happened before that.
        if let writer {
            self.writer = nil
            if frames > 0 {
                try? await writer.finish()
            }
        }
        state = .failed
        failure = error.localizedDescription
    }

    private func makeWriter(
        geometry: WindowRecordingFrameGeometry
    ) throws -> WindowRecordingFrameWriter {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)
        switch request.format {
        case .mp4:
            return try WindowRecordingMP4Writer(
                url: outputURL,
                width: geometry.outputWidth,
                height: geometry.outputHeight,
                framesPerSecond: request.framesPerSecond
            )
        case .gif:
            return try WindowRecordingGIFWriter(
                url: outputURL,
                frameBudget: request.frameBudget,
                framesPerSecond: request.framesPerSecond
            )
        }
    }

    private struct Sample {
        let image: CGImage
        let pointPixelScale: Double
    }

    private func resolveFilter() async throws -> SCContentFilter {
        if #available(macOS 14.4, *) {
            // The current-process query captures cmux's own windows without
            // Screen Recording permission, and cannot reach another app's
            // windows even if that permission was granted.
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.currentProcess
            } catch {
                throw WindowRecordingSessionError.captureFailed(error.localizedDescription)
            }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw WindowRecordingSessionError.windowGone
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        throw WindowRecordingSessionError.unsupportedSystem
    }

    private func sample() async throws -> Sample {
        guard let filter else { throw WindowRecordingSessionError.windowGone }
        let info = SCShareableContent.info(for: filter)
        let pixelScale = Double(info.pointPixelScale) > 0 ? Double(info.pointPixelScale) : 1
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((Double(info.contentRect.width) * pixelScale).rounded(.up)))
        configuration.height = max(1, Int((Double(info.contentRect.height) * pixelScale).rounded(.up)))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return Sample(image: image, pointPixelScale: pixelScale)
        } catch {
            throw WindowRecordingSessionError.captureFailed(error.localizedDescription)
        }
    }
}
