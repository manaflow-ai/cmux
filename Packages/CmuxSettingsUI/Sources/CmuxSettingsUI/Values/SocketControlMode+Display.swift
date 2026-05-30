import CmuxSettings
import Foundation

/// UI-facing labels for ``SocketControlMode``, ported byte-for-byte
/// from the legacy `Sources/SocketControlSettings.swift` so the
/// Automation section reads and writes the exact same display strings
/// users saw before the package refactor.
extension SocketControlMode {
    /// Canonical UI ordering of the five modes. Matches legacy
    /// `SocketControlMode.uiCases` so the picker rows render in the
    /// same sequence.
    static var uiCases: [SocketControlMode] {
        [.off, .cmuxOnly, .automation, .password, .allowAll]
    }

    /// Short label shown in the Automation picker.
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

    /// One-sentence row subtitle explaining the security tradeoff.
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
