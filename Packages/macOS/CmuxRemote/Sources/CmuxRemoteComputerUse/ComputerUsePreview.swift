// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import CoreGraphics
import Foundation
import ImageIO
import os
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// The app's live preview of an agent's Computer Use (``PreviewStreamSession``): the window the
/// session works in, streamed by cmux Remote (it holds the Screen Recording grant; the app never
/// captures). The window is only ever the session's own (the one it captured before its last
/// action), and never an app the person blocked: protected, denied or answered Never, checked
/// against the engine's policy at each frame, so a deny-list edit applies to the next one. This
/// type holds the privacy gate, the size fit and the JPEG still that stands in when no stream starts.
enum ComputerUsePreview {
    /// Why no frame came back.
    enum Refusal: String, Error, Equatable, Sendable {
        /// The session has not worked in a window yet (or ended).
        case noWindow = "no_window"
        /// The window's app is protected, denied or answered Never (or cannot be named).
        case blocked = "app_blocked"
        /// The window is gone or could not be captured.
        case captureFailed = "capture_failed"
        /// cmux Remote lacks Screen Recording.
        case permission = "permission_missing"

        var message: String {
            switch self {
            case .noWindow: "this agent has not worked in a window yet"
            case .blocked: "the agent's window belongs to an app Computer Use keeps private"
            case .captureFailed: "the agent's window could not be captured"
            case .permission: "Screen Recording permission is not granted to cmux Remote"
            }
        }
    }

    /// The window a session captured last, and the app that owned it when it did
    /// (``ComputerUseActivityReporter/window(of:)``).
    struct SessionWindow: Equatable, Sendable {
        var window: UInt32
        /// Nil when the window's owner could not be read at the capture.
        var app: ComputerUseActivity.App?
    }

    /// The window a frame may show, decided before any capture: the session's own window (one it
    /// captured itself), still owned by the same app (bundle id, and process when both are known),
    /// that app named by bundle id and not blocked. Pure, so tests cover every refusal.
    static func gate(window: SessionWindow?, owner: ComputerUseActivity.App?,
                     blocked: (_ id: String, _ name: String) -> Bool) -> Result<UInt32, Refusal> {
        guard let window else { return .failure(.noWindow) }
        guard let owner else { return .failure(.noWindow) }
        // A window whose app has no bundle id cannot be checked against the deny list: not shown.
        guard let id = owner.id, !id.isEmpty else { return .failure(.blocked) }
        // The app the session captured the window of must be known and be the owner now: a window
        // id reused by another app, or a window the session never looked at, is not its window.
        guard let expected = window.app?.id, expected == id else { return .failure(.noWindow) }
        if let pid = window.app?.pid, let now = owner.pid, pid != now { return .failure(.noWindow) }
        guard !blocked(id, owner.name ?? id) else { return .failure(.blocked) }
        return .success(window.window)
    }

    /// The pixel size of a `width` x `height` frame scaled so its longest side is at most `longSide`
    /// (never scaled up).
    static func fitted(width: Double, height: Double, longSide: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let scale = min(1, Double(longSide) / max(width, height))
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    /// One JPEG of window `id` at most `longSide` pixels on its long side, without the pointer.
    /// Async: nothing waits on a thread for it, and the caller keeps one at a time.
    static func still(window id: UInt32, longSide: Int) async -> Result<(jpeg: Data, width: Int, height: Int), Refusal> {
        guard CGPreflightScreenCaptureAccess() else { return .failure(.permission) }
        return await capturedStill(window: id, longSide: longSide)
    }

    private static func capturedStill(window id: UInt32, longSide: Int) async -> Result<(jpeg: Data, width: Int, height: Int), Refusal> {
        do {
            // The cached listing while the window is where it was (4 frames a second need no fresh one).
            let content: SCShareableContent
            if let cached = ScreenCapture.reusableContent(holding: id) {
                content = cached
            } else {
                content = try await ScreenCapture.freshContent()
            }
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return .failure(.captureFailed) }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = Double(filter.pointPixelScale)
            let size = fitted(width: window.frame.width * scale, height: window.frame.height * scale, longSide: longSide)
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let jpeg = jpeg(image) else { return .failure(.captureFailed) }
            return .success((jpeg, image.width, image.height))
        } catch let error as SCStreamError where error.code == .userDeclined {
            return .failure(.permission)
        } catch {
            return .failure(.captureFailed)
        }
    }

    /// `image` as a JPEG, quality 0.72 (a 640 px window is tens of kilobytes).
    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
