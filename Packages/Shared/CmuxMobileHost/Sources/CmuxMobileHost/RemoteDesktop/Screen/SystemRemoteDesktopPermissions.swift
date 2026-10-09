#if os(macOS)
import ApplicationServices
import CoreGraphics

/// TCC preflight reads: never raises a prompt.
public struct SystemRemoteDesktopPermissions: RemoteDesktopPermissions {
    public init() {}

    public func isGranted(_ permission: RemoteDesktopPermission) async -> Bool {
        switch permission {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }
}
#endif
