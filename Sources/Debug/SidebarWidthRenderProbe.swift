import SwiftUI

#if DEBUG
/// Debug-only observation point for the width consumed by a rendered sidebar.
struct SidebarWidthRenderProbe {
    var widthRead: ((CGFloat) -> Void)?
}

private struct SidebarWidthRenderProbeKey: EnvironmentKey {
    static let defaultValue = SidebarWidthRenderProbe()
}

extension EnvironmentValues {
    var sidebarWidthRenderProbe: SidebarWidthRenderProbe {
        get { self[SidebarWidthRenderProbeKey.self] }
        set { self[SidebarWidthRenderProbeKey.self] = newValue }
    }
}
#endif
