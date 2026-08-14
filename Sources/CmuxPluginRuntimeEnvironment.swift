import SwiftUI

private struct CmuxPluginRuntimeEnvironmentKey: EnvironmentKey {
    static let defaultValue: CmuxPluginRuntime? = nil
}

extension EnvironmentValues {
    var cmuxPluginRuntime: CmuxPluginRuntime? {
        get { self[CmuxPluginRuntimeEnvironmentKey.self] }
        set { self[CmuxPluginRuntimeEnvironmentKey.self] = newValue }
    }
}
