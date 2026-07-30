import SwiftUI

#if os(iOS)
/// Extends the workspace table beneath the iOS 26 navigation and tab bars so
/// their native soft scroll-edge effects have content to blend.
///
/// ``WorkspaceListUITableView`` maps its live safe-area geometry to explicit
/// content insets for the underlapped frame. The table can therefore drive
/// both edge effects while its first and last rows remain outside the bars'
/// hit regions.
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
