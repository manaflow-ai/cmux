public import Foundation

/// ``VoiceRoomScreenReading`` on this Mac, through the cmux Computer Use helper
/// (``ChiefScreenCaptureHost``, the same `display_still` Share Screen with Chief uses): the helper
/// captures the main display with cmux's own windows left out (so the room page never reads itself
/// back) and compares the frame's signature; on a change, this app runs Vision's on-device text
/// recognition (``ChiefScreenHelperCapture``) and keeps the JPEG as a keyframe in `frames` (the newest
/// `keepFrames`). This app never captures the screen itself and never asks macOS for Screen
/// Recording. Nothing leaves the Mac here; the session sends only the text.
public struct VoiceRoomScreenReader: VoiceRoomScreenReading {
    private let capture: ChiefScreenHelperCapture
    private let frames: URL?
    private let keepFrames: Int

    /// - Parameters:
    ///   - host: The capture process (the cmux Computer Use helper).
    ///   - frames: Where keyframes go; nil keeps none.
    ///   - keepFrames: How many keyframes stay; older ones are deleted.
    ///   - threshold: The ``VoiceRoomFrameSignature/difference(to:)`` that counts as a change.
    ///   - maxCharacters: The most text one frame sends.
    public init(host: any ChiefScreenCaptureHost, frames: URL?, keepFrames: Int = 2000, threshold: Double = 0.02,
                maxCharacters: Int = 800) {
        capture = ChiefScreenHelperCapture(host: host, width: 1440, threshold: threshold, maxCharacters: maxCharacters)
        self.frames = frames
        self.keepFrames = keepFrames
    }

    /// - Throws: ``ChiefScreenCaptureInterruption`` while no helper answers or Screen Recording is not
    ///   allowed for it.
    @concurrent
    public func read(changedSince previous: VoiceRoomFrameSignature?) async throws -> VoiceRoomScreenSample? {
        guard let frame = try await capture.capture(changedSince: previous) else { return nil }
        saveKeyframe(frame.jpeg)
        return VoiceRoomScreenSample(signature: frame.signature, text: frame.text)
    }

    private func saveKeyframe(_ jpeg: Data) {
        guard let frames else { return }
        let files = FileManager.default
        try? files.createDirectory(at: frames, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        guard (try? jpeg.write(to: frames.appending(path: name), options: .atomic)) != nil else { return }
        let saved = ((try? files.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
        for old in saved.dropLast(keepFrames) { try? files.removeItem(at: frames.appending(path: old)) }
    }
}
