import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// ``ChiefScreenCapturing`` on this Mac: a ScreenCaptureKit still of the main display with the
/// excluded apps left out (``ChiefScreenShareExclusions``), compared by its 32x20 signature. Only a
/// changed frame pays for Vision's on-device text recognition and the JPEG. Nothing leaves the Mac.
public struct ChiefScreenSystemCapture: ChiefScreenCapturing {
    private let width: Int
    private let threshold: Double
    private let maxCharacters: Int
    private let exclusions: ChiefScreenShareExclusions

    /// - Parameters:
    ///   - width: The frame's width in pixels (its height follows the display).
    ///   - threshold: The ``VoiceRoomFrameSignature/difference(to:)`` that counts as a change.
    ///   - maxCharacters: The most text one frame keeps.
    ///   - exclusions: The apps left out of every frame.
    public init(width: Int = 1440, threshold: Double = 0.02, maxCharacters: Int = 1200,
                exclusions: ChiefScreenShareExclusions = ChiefScreenShareExclusions()) {
        self.width = width
        self.threshold = threshold
        self.maxCharacters = maxCharacters
        self.exclusions = exclusions
    }

    @concurrent
    public func isAllowed() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @concurrent
    public func requestAccess() async -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @concurrent
    public func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            return nil
        }
        let excluded = content.applications.filter { exclusions.excludes(bundleID: $0.bundleIdentifier, processID: $0.processID) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(1, Int(Double(width) * Double(display.height) / Double(max(display.width, 1))))
        configuration.showsCursor = false
        // perf-gate-ok: the capture the person turned on (Share Screen with Chief); off main, one still per interval.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let signature = VoiceRoomFrameSignature(image: image) else { return nil }
        if let previous, signature.difference(to: previous) < threshold { return nil }
        let front = frontWindow(excluded: Set(excluded.map(\.processID)))
        return ChiefScreenFrame(signature: signature, jpeg: jpeg(image) ?? Data(), text: (try? recognizeText(in: image)) ?? "",
                                app: front.app, window: front.window)
    }

    /// The front normal window's app and title, from the window server's front-to-back list,
    /// skipping excluded apps (their titles must not reach the Chief either).
    private func frontWindow(excluded: Set<pid_t>) -> (app: String?, window: String?) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return (nil, nil) }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, !excluded.contains(pid),
                  pid != exclusions.ownProcess else { continue }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (info[kCGWindowOwnerName as String] as? String, title)
        }
        return (nil, nil)
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

    private func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
