import SwiftUI

/// Defaults to the shipping behavior so previews and isolated package hosts
/// exercise the fully integrated terminal Files chip without extra setup.
private struct TerminalFilesChipEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the terminal Files chip and its count-only scan are enabled.
    public var terminalFilesChipEnabled: Bool {
        get { self[TerminalFilesChipEnabledKey.self] }
        set { self[TerminalFilesChipEnabledKey.self] = newValue }
    }
}

extension View {
    /// Applies the remotely controlled terminal Files chip availability.
    public func terminalFilesChipEnabled(_ isEnabled: Bool) -> some View {
        environment(\.terminalFilesChipEnabled, isEnabled)
    }
}
