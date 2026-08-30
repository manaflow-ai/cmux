import SwiftUI

#if DEBUG
/// Debug-only observation point for the width consumed by a rendered sidebar.
struct SidebarWidthRenderProbe {
    var widthRead: ((CGFloat) -> Void)?

    fileprivate struct RenderProbeEnvironmentKey: EnvironmentKey {
        static let defaultValue = SidebarWidthRenderProbe()
    }
}

extension EnvironmentValues {
    var sidebarWidthRenderProbe: SidebarWidthRenderProbe {
        get { self[SidebarWidthRenderProbe.RenderProbeEnvironmentKey.self] }
        set { self[SidebarWidthRenderProbe.RenderProbeEnvironmentKey.self] = newValue }
    }
}
#endif
