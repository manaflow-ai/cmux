import SwiftUI

#if os(iOS)
/// Gives the native iOS 26 soft scroll-edge effects table pixels to process
/// beneath the navigation and tab bars.
///
/// The table remains a normal UIKit scroll view, so UIKit supplies its safe
/// area and adjusted content inset while the table itself remains visually
/// present beneath the bars' effects.
struct WorkspaceListBarUnderlap: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The terminal or composer owns keyboard avoidance. Keep the
            // workspace table full height during their keyboard transitions.
            content.ignoresSafeArea([.container, .keyboard], edges: .vertical)
        } else {
            content
        }
    }
}
#endif
