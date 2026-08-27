import SwiftUI

#if os(iOS)
/// Gives the native iOS 26 soft scroll-edge effects table pixels to process
/// beneath the navigation and tab bars.
///
/// ``WorkspaceListTableViewController`` maps the enclosing UIKit controller's
/// safe layout frame back into this underlapped table's safe area. UIKit then
/// keeps interactive rows outside the bars while the table itself remains
/// visually present beneath their effects.
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
