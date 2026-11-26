import SwiftUI

#if DEBUG
extension EnvironmentValues {
    var sidebarLazyContractProbe: SidebarLazyContractProbe {
        get { self[SidebarLazyContractProbeKey.self] }
        set { self[SidebarLazyContractProbeKey.self] = newValue }
    }
}
#endif
