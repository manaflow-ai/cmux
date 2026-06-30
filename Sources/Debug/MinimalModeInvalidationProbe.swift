import SwiftUI

#if DEBUG
struct MinimalModeInvalidationProbe {
    var contentViewBody: (() -> Void)?
    var workspaceContentBody: (() -> Void)?
    var verticalTabsSidebarBody: (() -> Void)?
}

private struct MinimalModeInvalidationProbeKey: EnvironmentKey {
    static let defaultValue = MinimalModeInvalidationProbe()
}

extension EnvironmentValues {
    var minimalModeInvalidationProbe: MinimalModeInvalidationProbe {
        get { self[MinimalModeInvalidationProbeKey.self] }
        set { self[MinimalModeInvalidationProbeKey.self] = newValue }
    }
}
#endif
