public import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// ``VoiceRoomScreenReading`` on this Mac: a ScreenCaptureKit still of the main display (cmux's own
/// windows left out, so the room page never reads itself back), compared by signature, and on a
/// change, Vision's on-device text recognition plus a JPEG keyframe kept in `frames` (the newest
/// `keepFrames`). Nothing leaves the Mac here; the session sends only the text.
public struct VoiceRoomScreenReader: VoiceRoomScreenReading {
    private let frames: URL?
    private let keepFrames: Int
    private let threshold: Double
    private let maxCharacters: Int

    /// - Parameters:
    ///   - frames: Where keyframes go; nil keeps none.
    ///   - keepFrames: How many keyframes stay; older ones are deleted.
    ///   - threshold: The ``VoiceRoomFrameSignature/difference(to:)`` that counts as a change.
    ///   - maxCharacters: The most text one frame sends.
    public init(frames: URL?, keepFrames: Int = 2000, threshold: Double = 0.02, maxCharacters: Int = 800) {
        self.frames = frames
        self.keepFrames = keepFrames
        self.threshold = threshold
        self.maxCharacters = maxCharacters
    }

    @concurrent
    public func read(changedSince previous: VoiceRoomFrameSignature?) async throws -> VoiceRoomScreenSample? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            return nil
        }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 1440
        configuration.height = max(1, Int(1440 * Double(display.height) / Double(max(display.width, 1))))
        configuration.showsCursor = false
        // perf-gate-ok: the capture the person turned on (labs.voiceRoom, Open Voice Room); off main, one still per interval.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let signature = VoiceRoomFrameSignature(image: image) else { return nil }
        if let previous, signature.difference(to: previous) < threshold { return nil }
        let text = try recognizeText(in: image)
        saveKeyframe(image)
        return VoiceRoomScreenSample(signature: signature, text: text)
    }

    private func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: " · ").prefix(maxCharacters))
    }

    private func saveKeyframe(_ image: CGImage) {
        guard let frames else { return }
        let files = FileManager.default
        try? files.createDirectory(at: frames, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        guard let destination = CGImageDestinationCreateWithURL(frames.appending(path: name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
        let saved = ((try? files.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
        for old in saved.dropLast(keepFrames) { try? files.removeItem(at: frames.appending(path: old)) }
    }
}
