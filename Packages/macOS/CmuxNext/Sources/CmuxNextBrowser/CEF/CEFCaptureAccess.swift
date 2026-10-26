import AVFoundation
import Foundation

/// A device a Chromium page may capture once its site is allowed.
nonisolated enum CEFCapture: Hashable, Sendable {
    case camera
    case microphone

    /// What the request needs from macOS (camera pan, tilt and zoom is the camera).
    static func needed(by kind: BrowserPermissionKind) -> [CEFCapture] {
        switch kind {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
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
    /// Asks macOS for each capture still undecided.
    func authorize(_ captures: [CEFCapture]) async
}

/// The system's answers: `AVCaptureDevice` for the camera and microphone.
struct SystemCaptureAccess: CEFCaptureAccess {
    func authorize(_ captures: [CEFCapture]) async {
        for capture in captures {
            let type: AVMediaType = capture == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: type)
            }
        }
    }
}
