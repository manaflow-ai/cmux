import AVFoundation
import CoreGraphics
import Foundation

/// A device or the screen a Chromium page may capture once its site is allowed.
nonisolated enum CEFCapture: Hashable, Sendable {
    case camera
    case microphone
    case screen

    /// What the request needs from macOS (camera pan, tilt and zoom is the camera).
    static func needed(by kind: BrowserPermissionKind) -> [CEFCapture] {
        switch kind {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        case .screen: return [.screen]
        case .capabilities(let items):
            var captures: [CEFCapture] = []
            if items.contains(.camera) || items.contains(.cameraPanTiltZoom) { captures.append(.camera) }
            if items.contains(.microphone) { captures.append(.microphone) }
            return captures
        case .automaticDownloads, .location, .notifications: return []
        }
    }
}

/// macOS privacy access (TCC) for a capture. cmux asks for it after the
/// person allows the site and before Chromium hears the answer, so the
/// system prompt names cmux, never the Chromium Host or a helper; Chrome asks
/// in the same order (chrome/browser/media/webrtc/system_media_capture_permissions_mac.mm).
@MainActor
protocol CEFCaptureAccess {
    /// Asks macOS for each capture still undecided; true when all are allowed.
    func authorize(_ captures: [CEFCapture]) async -> Bool
}

/// The system's answers: `AVCaptureDevice` for the camera and microphone,
/// `CGRequestScreenCaptureAccess` for Screen Recording.
struct SystemCaptureAccess: CEFCaptureAccess {
    func authorize(_ captures: [CEFCapture]) async -> Bool {
        for capture in captures {
            let allowed: Bool
            switch capture {
            case .camera: allowed = await Self.device(.video)
            case .microphone: allowed = await Self.device(.audio)
            case .screen: allowed = await Self.screen()
            }
            if !allowed { return false }
        }
        return true
    }

    private static func device(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    /// Screen Recording: macOS asks once and the grant counts after a
    /// relaunch, so an undecided answer refuses this share. The request is an
    /// IPC to the privacy daemon, so it runs off the main thread.
    @concurrent
    private nonisolated static func screen() async -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }
}
