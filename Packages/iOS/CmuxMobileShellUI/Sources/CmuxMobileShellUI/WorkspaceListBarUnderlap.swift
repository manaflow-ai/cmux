import SwiftUI

#if os(iOS)
/// Extends the workspace table beneath the iOS 26 navigation and tab bars so
/// their native soft scroll-edge effects have content to blend.
///
/// UIKit adjusts the registered table's content insets, keeping the first and
/// last rows outside the bars' hit regions without mutating scroll position.
struct WorkspaceListBarUnderlap: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.ignoresSafeArea(.container, edges: .vertical)
        } else {
            content
        }
    }
}
#endif
