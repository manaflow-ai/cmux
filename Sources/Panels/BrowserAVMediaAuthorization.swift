import AVFoundation
import CmuxBrowser

/// macOS's camera/microphone permission for cmux, read from AVFoundation
/// (design spec §4 v1.4). `requestAccess` shows macOS's own prompt, so it runs
/// only after the person allowed the site in cmux's strip.
@MainActor
final class BrowserAVMediaAuthorization: BrowserMediaAuthorizationProviding {
    static let shared = BrowserAVMediaAuthorization()

    func authorization(for device: BrowserMediaDevice) -> BrowserMediaAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: Self.mediaType(device)) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    func requestAccess(for device: BrowserMediaDevice) async -> Bool {
        await AVCaptureDevice.requestAccess(for: Self.mediaType(device))
    }

    private static func mediaType(_ device: BrowserMediaDevice) -> AVMediaType {
        switch device {
        case .camera: .video
        case .microphone: .audio
        }
    }
}
