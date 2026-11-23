import AVFoundation
import CoreGraphics

/// Asks macOS for an upstream kind's permission. The pane calls it only from
/// the user's explicit per-kind action, never at launch.
@MainActor
public protocol RemoteUpstreamPermissions {
    /// True when the permission is granted (asking first when undetermined).
    func request(_ kind: RemoteUpstreamKind) async -> Bool
}

/// The system prompts: microphone and camera through AVFoundation, screen
/// share through the screen recording permission.
public struct SystemUpstreamPermissions: RemoteUpstreamPermissions {
    public init() {}

    public func request(_ kind: RemoteUpstreamKind) async -> Bool {
        switch kind {
        case .microphone: await AVCaptureDevice.requestAccess(for: .audio)
        case .camera: await AVCaptureDevice.requestAccess(for: .video)
        // This app's own grant: the prompt shows once and the grant takes effect after a relaunch. No
        // capturer sends this Mac's screen upstream yet; one must run in the Screen Sharing helper
        // (plans/cmux-next/screen-sharing-helper.md) and ask the helper here, or it keeps the relaunch.
        case .screen: CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        }
    }
}
