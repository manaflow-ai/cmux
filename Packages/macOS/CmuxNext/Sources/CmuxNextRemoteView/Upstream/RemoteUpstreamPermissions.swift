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
        // Shows the system prompt once; the grant takes effect after a relaunch.
        case .screen: CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        }
    }
}
