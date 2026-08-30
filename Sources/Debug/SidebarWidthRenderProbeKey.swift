import SwiftUI

#if DEBUG
/// Environment key for the debug-only sidebar width render probe.
struct SidebarWidthRenderProbeKey: EnvironmentKey {
    static let defaultValue = SidebarWidthRenderProbe()
}
#endif
