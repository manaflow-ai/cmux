import SwiftUI

#if DEBUG
struct SidebarLazyContractProbeKey: EnvironmentKey {
    static let defaultValue = SidebarLazyContractProbe()
}
#endif
