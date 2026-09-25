import SwiftUI

/// Defaults to the shipping behavior (legacy keyboard pinning everywhere) so
/// previews and isolated package hosts never depend on the control plane.
private struct KeyboardDockRebuildRevertEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the remote kill switch reverts iOS ≤26 terminal keyboard
    /// pinning to the rebuilt dock path. Terminal hosts snapshot this at
    /// mount, so a change applies when the workspace is reopened.
    public var keyboardDockRebuildRevertEnabled: Bool {
        get { self[KeyboardDockRebuildRevertEnabledKey.self] }
        set { self[KeyboardDockRebuildRevertEnabledKey.self] = newValue }
    }
}

extension View {
    /// Applies the remotely controlled keyboard-rebuild revert kill switch.
    public func keyboardDockRebuildRevertEnabled(_ isEnabled: Bool) -> some View {
        environment(\.keyboardDockRebuildRevertEnabled, isEnabled)
    }
}
