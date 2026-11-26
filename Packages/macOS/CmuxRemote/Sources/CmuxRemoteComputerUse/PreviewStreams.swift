// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import os
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// The live preview's window streams, the engine's `preview` host callback (cmux_computer_use.h):
/// one ScreenCaptureKit stream per window the engine names, scaled to its long side, at most its
/// frame rate, without the pointer. Each new frame goes back to the engine as JPEG; a stream whose
/// window closed is reported. Nothing else lives here: which windows stream, for which agent and
/// surface, and when, is the engine's (cmux-computer-use preview.rs).
final class PreviewStreams: @unchecked Sendable { // crash-allow: `streams` is touched only under `lock`
    /// What the engine asks for: the exact set of windows, their long side and frame rate.
    struct Request: Equatable {
        var windows: [String]
        var longSide: Int
        var fps: Int
        var generation: UInt64

        init?(json: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  let windows = object["windows"] as? [String] else { return nil }
            self.windows = windows
            longSide = max(64, min((object["long_side"] as? Int) ?? 960, 4096))
            fps = max(1, min((object["fps"] as? Int) ?? 12, 60))
            generation = (object["generation"] as? NSNumber).map(\.uint64Value) ?? 0
        }
    }

    private let frame: @Sendable (String, UInt64, Data) -> Void
    private let closed: @Sendable (String, UInt64) -> Void
    private let lock = NSLock()
    private var streams: [String: WindowStream] = [:]
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - frame: A new JPEG frame of a window and its stream generation (any thread).
    ///   - closed: A window's stream ended because the window went away (any thread).
    init(frame: @escaping @Sendable (String, UInt64, Data) -> Void,
         closed: @escaping @Sendable (String, UInt64) -> Void) {
        self.frame = frame
        self.closed = closed
    }

    /// Streams exactly the request's windows from now on. Returns at once.
    func set(_ json: Data) {
        guard let request = Request(json: json) else { return }
        let (stop, start) = lock.withLock { () -> ([WindowStream], [WindowStream]) in
            // Stream requests can be delivered out of order because the
            // engine does not call the host while holding its state lock.
            // Never let an older request resurrect a stream we replaced.
            guard request.generation >= generation else { return ([], []) }
            let replaces = request.generation != generation
            generation = request.generation
            let wanted = Set(request.windows)
            let stop = streams.filter { !wanted.contains($0.key) || replaces || $0.value.generation != request.generation }.map(\.value)
            for gone in stop { streams.removeValue(forKey: gone.window) }
            var start: [WindowStream] = []
            for window in request.windows where streams[window] == nil {
                let stream = WindowStream(window: window, generation: request.generation,
                                          longSide: request.longSide, fps: request.fps,
                                          frame: frame, ended: { [weak self] stream in self?.ended(stream) })
                streams[window] = stream
                start.append(stream)
            }
            return (stop, start)
        }
        for stream in stop { stream.stop() }
        for stream in start { stream.start() }
    }

    /// A stream ended on its own (its window closed, or ScreenCaptureKit stopped it).
    private func ended(_ stream: WindowStream) {
        let current = lock.withLock { () -> Bool in
            guard streams[stream.window] === stream else { return false }
            streams.removeValue(forKey: stream.window)
            return true
        }
        if current { closed(stream.window, stream.generation) }
    }

    func stopAll() {
        let all = lock.withLock { () -> [WindowStream] in
            defer { streams.removeAll() }
            return Array(streams.values)
        }
        for stream in all { stream.stop() }
    }
}

/// One window's ScreenCaptureKit stream: frames only when the window changes, each as JPEG.
final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable { // crash-allow: `stream`/`stopped` are touched only under `lock`
    let window: String
    let generation: UInt64
    private let longSide: Int
    private let fps: Int
    private let frame: @Sendable (String, UInt64, Data) -> Void
    private let ended: @Sendable (WindowStream) -> Void
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private let queue = DispatchQueue(label: "remote-cu-preview-frames", qos: .utility)
    private static let logger = Logger(subsystem: "com.cmuxterm.remote", category: "computer-use-preview")

    init(window: String, generation: UInt64, longSide: Int, fps: Int,
         frame: @escaping @Sendable (String, UInt64, Data) -> Void,
         ended: @escaping @Sendable (WindowStream) -> Void) {
        self.window = window
        self.generation = generation
        self.longSide = longSide
        self.fps = fps
        self.frame = frame
        self.ended = ended
    }

    func start() {
        guard let id = UInt32(window) else { return ended(self) }
        // task-owner: one stream start; `stop()` before it finishes stops the stream it made.
        Task.detached(priority: .utility) { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let target = content.windows.first(where: { $0.windowID == id }) else { return ended(self) }
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let configuration = SCStreamConfiguration()
                let scale = Double(filter.pointPixelScale)
                let width = target.frame.width * scale, height = target.frame.height * scale
                let fit = min(1, Double(longSide) / max(width, height, 1))
                configuration.width = max(2, Int((width * fit).rounded()))
                configuration.height = max(2, Int((height * fit).rounded()))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                let keep = lock.withLock { () -> Bool in
                    guard !stopped else { return false }
                    self.stream = stream
                    return true
                }
                guard keep else { return }
                try await stream.startCapture()
            } catch {
                Self.logger.error("preview stream of window \(self.window, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                ended(self)
            }
        }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            stopped = true
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        // task-owner: one stop; nothing waits for it.
        Task.detached(priority: .utility) { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixels = sampleBuffer.imageBuffer, let jpeg = Self.jpeg(pixels) else { return }
        frame(window, generation, jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let ours = lock.withLock { !stopped }
        if ours { ended(self) }
    }

    /// Only a frame with new content (`.complete`); `.idle` repeats the last one.
    private static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private static func jpeg(_ pixels: CVPixelBuffer) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
