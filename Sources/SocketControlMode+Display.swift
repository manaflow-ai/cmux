import CmuxSettings
import Foundation

// `SocketControlMode` lives in CmuxSettings (a value type with no UI concerns).
// Identifiable is a presentation concern used by SwiftUI ForEach/Picker in this target,
// so the conformance is added retroactively here rather than in the package.
extension SocketControlMode: @retroactive Identifiable {
    public var id: String { rawValue }
}

extension SocketControlMode {
    /// The cases shown in Settings, in display order.
    static var uiCases: [SocketControlMode] { [.off, .cmuxOnly, .automation, .password, .allowAll] }

    /// The localized name shown in Settings for this mode.
    var displayName: String {
        switch self {
        case .off:
            return String(localized: "socketControl.off.name", defaultValue: "Off")
        case .cmuxOnly:
            return String(localized: "socketControl.cmuxOnly.name", defaultValue: "cmux processes only")
        case .automation:
            return String(localized: "socketControl.automation.name", defaultValue: "Automation mode")
        case .password:
            return String(localized: "socketControl.password.name", defaultValue: "Password mode")
        case .allowAll:
            return String(localized: "socketControl.allowAll.name", defaultValue: "Full open access")
        }
    }

    /// The localized description shown in Settings for this mode.
    var description: String {
        switch self {
        case .off:
            return String(localized: "socketControl.off.description", defaultValue: "Disable the local control socket.")
        case .cmuxOnly:
            return String(localized: "socketControl.cmuxOnly.description", defaultValue: "Only processes started inside cmux terminals can send commands.")
        case .automation:
            return String(localized: "socketControl.automation.description", defaultValue: "Allow external local automation clients from this macOS user (no ancestry check).")
        case .password:
            return String(localized: "socketControl.password.description", defaultValue: "Require socket authentication with a password stored in a local file.")
        case .allowAll:
            return String(localized: "socketControl.allowAll.description", defaultValue: "Allow any local process and user to connect with no auth. Unsafe.")
        }
    }
}
