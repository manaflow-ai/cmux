import AVFoundation
import Foundation
import ScreenCaptureKit

#if DEBUG
/// Records one of cmux's own windows to an H.264 `.mov` for animation checks (DEBUG only).
///
/// The filter is `SCContentFilter(desktopIndependentWindow:)` over a window from
/// `SCShareableContent.currentProcess`, so only that window's pixels are captured: never
/// other apps, other cmux windows, or the desktop, and no Screen Recording prompt.
actor DebugWindowRecorder {
    private var stream: SCStream?
    // SCRecordingOutput and its delegate are macOS 15 types; held untyped so the actor
    // itself stays available on macOS 14, where `start` reports the requirement.
    private var output: AnyObject?
    private var delegate: AnyObject?
    private var path: String?

    enum RecorderError: Error, CustomStringConvertible {
        case alreadyRecording
        case notRecording
        case windowNotFound
        case unsupported
        case failed(String)

        var description: String {
            switch self {
            case .alreadyRecording: return "a recording is already running"
            case .notRecording: return "no recording is running"
            case .windowNotFound: return "window not found among this process's windows"
            case .unsupported: return "window recording needs macOS 15"
            case .failed(let message): return message
            }
        }
    }

    /// Starts recording window `windowID` at up to 60 fps into `url`.
    func start(windowID: CGWindowID, url: URL) async throws {
        guard stream == nil else { throw RecorderError.alreadyRecording }
        guard #available(macOS 15.0, *) else { throw RecorderError.unsupported }
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RecorderError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(ceil(info.contentRect.width * scale)) & ~1)
        configuration.height = max(2, Int(ceil(info.contentRect.height * scale)) & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.queueDepth = 8

        try? FileManager.default.removeItem(at: url)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        let delegate = FinishDelegate()
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        self.delegate = delegate
        self.path = url.path
    }

    /// Stops the recording and waits until the file is finalized.
    /// - Returns: The file path.
    func stop() async throws -> String {
        guard #available(macOS 15.0, *) else { throw RecorderError.unsupported }
        guard let stream, let delegate = delegate as? FinishDelegate, let path else { throw RecorderError.notRecording }
        self.stream = nil
        self.output = nil
        self.delegate = nil
        self.path = nil
        try await stream.stopCapture()
        try await delegate.finished()
        return path
    }

    /// Bridges `SCRecordingOutputDelegate` finish/failure callbacks to async.
    @available(macOS 15.0, *)
    private final class FinishDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
        // Callbacks arrive on ScreenCaptureKit's queue and `finished()` may race them; the
        // lock guards only this one-shot result/continuation handoff.
        private let lock = NSLock()
        private var result: Result<Void, any Error>?
        private var continuation: CheckedContinuation<Void, any Error>?

        func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            complete(.success(()))
        }

        func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
            complete(.failure(error))
        }

        private func complete(_ value: Result<Void, any Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: value)
        }

        func finished() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}
#endif
