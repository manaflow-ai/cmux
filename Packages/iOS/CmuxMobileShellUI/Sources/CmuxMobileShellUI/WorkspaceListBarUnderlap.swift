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
    /// The workspace list is not an input surface. Its keyboard-safe region
    /// belongs to the terminal or composer that is presented above it, so a
    /// keyboard transition must not resize the represented table.
    static let ignoredSafeAreaRegions: SafeAreaRegions = [.container]

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.ignoresSafeArea(Self.ignoredSafeAreaRegions, edges: .vertical)
        } else {
            content
        }
    }
}
#endif
