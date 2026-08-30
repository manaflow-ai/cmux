import SwiftUI

#if DEBUG
/// Debug-only observation point for the width consumed by a rendered sidebar.
struct SidebarWidthRenderProbe {
    var widthRead: ((CGFloat) -> Void)?
}
#endif
