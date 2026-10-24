public import Foundation

/// A Privacy & Security list the helper app must be in.
public nonisolated enum ComputerUsePermissionPane: String, CaseIterable, Sendable {
    case accessibility, screenRecording

    /// The pane's list in System Settings (Privacy & Security).
    public var settingsURL: URL? {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}
