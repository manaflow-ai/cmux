public import Foundation
import CoreGraphics
import ImageIO
import Vision

/// What one look at the main display asks the capture process for (the helper's host-only `display_still`).
public struct ChiefScreenStillRequest: Sendable, Equatable {
    /// The frame's width in pixels; its height follows the display.
    public var width: Int
    /// The apps whose windows are left out (``ChiefScreenShareExclusions``).
    public var exclusions: ChiefScreenShareExclusions
    /// The last frame's thumbnail; nil always answers a frame.
    public var previous: VoiceRoomFrameSignature?
    /// The ``VoiceRoomFrameSignature/difference(to:)`` that counts as a change.
    public var threshold: Double
    /// JPEG quality, 1 to 95.
    public var quality: Int

    public init(width: Int, exclusions: ChiefScreenShareExclusions, previous: VoiceRoomFrameSignature?, threshold: Double,
                quality: Int) {
        self.width = width
        self.exclusions = exclusions
        self.previous = previous
        self.threshold = threshold
        self.quality = quality
    }
}

/// One look at the main display, as the capture process answers it.
public struct ChiefScreenStill: Sendable, Equatable {
    /// This frame's thumbnail.
    public var signature: VoiceRoomFrameSignature
    /// The JPEG, nil when the frame looks the same as the request's `previous`.
    public var jpeg: Data?
    /// The front window's app and title, excluded apps never named.
    public var app: String?
    public var window: String?

    public init(signature: VoiceRoomFrameSignature, jpeg: Data?, app: String? = nil, window: String? = nil) {
        self.signature = signature
        self.jpeg = jpeg
        self.app = app
        self.window = window
    }
}

/// The process that holds Screen Recording for Share Screen with Chief: the cmux Computer Use helper, so
/// macOS asks for (and, after a grant, relaunches) the helper, never cmux.app. Plain Foundation types,
/// so the helper's socket client (CmuxNextComputerUse) answers it without depending on this package;
/// the App declares the conformance. Tests pass a fake.
public protocol ChiefScreenCaptureHost: Sendable {
    /// Whether Screen Recording is allowed for the helper.
    @concurrent func screenRecordingAllowed() async throws -> Bool
    /// Raises macOS's Screen Recording request for the helper.
    @concurrent func requestScreenRecording() async throws
    /// One `display_still` (``ChiefScreenStillWire``): its arguments and the helper's reply.
    @concurrent func displayStill(_ arguments: [String: Any]) async throws -> [String: Any]
    /// Whether `error` means no helper answers now (starting, or relaunching after a grant).
    func isHelperGone(_ error: any Error) -> Bool
    /// The helper's refusal text in `error`; nil when `error` is no refusal.
    func refusal(_ error: any Error) -> String?
}

/// ``ChiefScreenCapturing`` through the helper (``ChiefScreenCaptureHost``): the helper captures the
/// main display with the excluded apps left out and compares the frame's 32x20 signature, so an
/// unchanged screen costs one small reply. Only a changed frame comes back as a JPEG, and only then
/// does this app pay for Vision's on-device text recognition. This app never captures the screen
/// itself and never asks macOS for Screen Recording. Nothing leaves the Mac.
public struct ChiefScreenHelperCapture: ChiefScreenCapturing {
    private let host: any ChiefScreenCaptureHost
    private let width: Int
    private let threshold: Double
    private let maxCharacters: Int
    private let exclusions: ChiefScreenShareExclusions

    /// - Parameters:
    ///   - host: The capture process.
    ///   - width: The frame's width in pixels (its height follows the display).
    ///   - threshold: The ``VoiceRoomFrameSignature/difference(to:)`` that counts as a change.
    ///   - maxCharacters: The most text one frame keeps.
    ///   - exclusions: The apps left out of every frame.
    public init(host: any ChiefScreenCaptureHost, width: Int = 1440, threshold: Double = 0.02, maxCharacters: Int = 1200,
                exclusions: ChiefScreenShareExclusions = ChiefScreenShareExclusions()) {
        self.host = host
        self.width = width
        self.threshold = threshold
        self.maxCharacters = maxCharacters
        self.exclusions = exclusions
    }

    @concurrent
    public func isAllowed() async throws -> Bool {
        do { return try await host.screenRecordingAllowed() } catch { throw interruption(error) }
    }

    @concurrent
    public func requestAccess() async throws -> Bool {
        do {
            try await host.requestScreenRecording()
            return try await host.screenRecordingAllowed()
        } catch {
            throw interruption(error)
        }
    }

    @concurrent
    public func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame? {
        let request = ChiefScreenStillRequest(width: width, exclusions: exclusions, previous: previous, threshold: threshold,
                                              quality: 60)
        let reply: [String: Any]
        do { reply = try await host.displayStill(ChiefScreenStillWire.arguments(request)) } catch { throw interruption(error) }
        guard let still = ChiefScreenStillWire.still(reply) else { throw ChiefScreenStillWire.Malformed() }
        guard let jpeg = still.jpeg else { return nil }
        let text = Self.image(jpeg).flatMap { try? recognizeText(in: $0) } ?? ""
        return ChiefScreenFrame(signature: still.signature, jpeg: jpeg, text: text, app: still.app, window: still.window)
    }

    /// The ``ChiefScreenCaptureInterruption`` `error` means, else `error` itself.
    private func interruption(_ error: any Error) -> any Error {
        if host.isHelperGone(error) { return ChiefScreenCaptureInterruption.unavailable }
        if let refusal = host.refusal(error), let interruption = ChiefScreenStillWire.interruption(refusal: refusal) {
            return interruption
        }
        return error
    }

    static func image(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
}
