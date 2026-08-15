import SwiftUI

#if DEBUG
extension EnvironmentValues {
    var minimalModeInvalidationProbe: MinimalModeInvalidationProbe {
        get { self[MinimalModeInvalidationProbeKey.self] }
        set { self[MinimalModeInvalidationProbeKey.self] = newValue }
    }
}
#endif
