#if DEBUG
import CMUXMobileCore
import SwiftUI

private struct MobileReleaseGateUIProbeKey: EnvironmentKey {
    static let defaultValue: MobileReleaseGateUIProbe? = nil
}

extension EnvironmentValues {
    public var releaseGateUIProbe: MobileReleaseGateUIProbe? {
        get { self[MobileReleaseGateUIProbeKey.self] }
        set { self[MobileReleaseGateUIProbeKey.self] = newValue }
    }
}
#endif
