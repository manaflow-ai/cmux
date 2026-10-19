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
}
