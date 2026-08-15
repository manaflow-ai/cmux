import SwiftUI

#if DEBUG
struct MinimalModeInvalidationProbeKey: EnvironmentKey {
    static let defaultValue = MinimalModeInvalidationProbe()
}
#endif
