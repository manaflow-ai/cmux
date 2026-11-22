import AVFoundation

/// Asks macOS for an upstream kind's permission. The pane calls it only from
/// the user's explicit per-kind action, never at launch.
@MainActor
public protocol RemoteUpstreamPermissions {
    /// True when the permission is granted (asking first when undetermined).
    func request(_ kind: RemoteUpstreamKind) async -> Bool
}

/// The system prompts: microphone and camera through AVFoundation. Screen share is refused here:
/// this app never asks macOS for Screen Recording (the Screen Sharing helper holds every screen
/// grant, `GrantHolding`), and nothing in the app captures the screen to send upstream, so asking
/// would only list "cmux" in Privacy & Security for nothing.
public struct SystemUpstreamPermissions: RemoteUpstreamPermissions {
    public init() {}

    public func request(_ kind: RemoteUpstreamKind) async -> Bool {
        switch kind {
        case .microphone: await AVCaptureDevice.requestAccess(for: .audio)
        case .camera: await AVCaptureDevice.requestAccess(for: .video)
        case .screen: false
        }
    }
}
