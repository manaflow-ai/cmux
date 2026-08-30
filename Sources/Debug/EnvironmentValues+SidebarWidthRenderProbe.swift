import SwiftUI

#if DEBUG
extension EnvironmentValues {
    var sidebarWidthRenderProbe: SidebarWidthRenderProbe {
        get { self[SidebarWidthRenderProbeKey.self] }
        set { self[SidebarWidthRenderProbeKey.self] = newValue }
    }
}
#endif
