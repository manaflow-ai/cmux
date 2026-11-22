public import Foundation
import CmuxNextCompat
public import CmuxNextComputerUse
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import Vision

/// ``VoiceRoomScreenReading`` on this Mac: a still of the main display (cmux's own windows left
/// out, so the room page never reads itself back), compared by signature, and on a change, Vision's
/// on-device text recognition plus a JPEG keyframe kept in `frames` (the newest `keepFrames`).
/// Nothing leaves the Mac here; the session sends only the text.
///
/// The still comes from the Screen Sharing helper (``GrantHolding``), the one bundle that holds this
/// Mac's Screen Recording grant: this app never captures the screen or asks macOS for it, so macOS
/// never lists cmux. Without the grant the first look asks for it once, naming the helper.
public struct VoiceRoomScreenReader: VoiceRoomScreenReading {
    private let frames: URL?
    private let keepFrames: Int
    private let threshold: Double
    private let maxCharacters: Int
    private let holder: (any GrantHolding)?
    private let asked = AskedOnce()

    /// - Parameters:
    ///   - frames: Where keyframes go; nil keeps none.
    ///   - keepFrames: How many keyframes stay; older ones are deleted.
    ///   - threshold: The ``VoiceRoomFrameSignature/difference(to:)`` that counts as a change.
    ///   - maxCharacters: The most text one frame sends.
    ///   - holder: Who takes the still (the Screen Sharing helper; tests pass a fake).
    public init(frames: URL?, keepFrames: Int = 2000, threshold: Double = 0.02, maxCharacters: Int = 800,
                holder: (any GrantHolding)? = ScreenSharingHelperGrants()) {
        self.frames = frames
        self.keepFrames = keepFrames
        self.threshold = threshold
        self.maxCharacters = maxCharacters
        self.holder = holder
    }

    /// The screen could not be read: no Screen Sharing helper, or it lacks Screen Recording.
    public struct Unreadable: Error, Equatable {
        public var notGranted: Bool
    }

    @concurrent
    public func read(changedSince previous: VoiceRoomFrameSignature?) async throws -> VoiceRoomScreenSample? {
        guard let holder else { throw Unreadable(notGranted: false) }
        let image: CGImage
        switch await holder.screenStill(maxWidth: 1440, excluding: getpid()) {
        case let .pixels(still):
            guard let picture = still.image else { throw Unreadable(notGranted: false) }
            image = picture
        case .notGranted:
            // The person opened the room (labs.voiceRoom, Open Voice Room): macOS asks once, for the helper.
            if asked.first() { await holder.requestScreenRecording() }
            throw Unreadable(notGranted: true)
        case .unavailable: throw Unreadable(notGranted: false)
        }
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

/// True the first time only, from any thread: one Screen Recording ask per reader.
private final class AskedOnce: Sendable {
    private let done = Mutex(false)

    func first() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
