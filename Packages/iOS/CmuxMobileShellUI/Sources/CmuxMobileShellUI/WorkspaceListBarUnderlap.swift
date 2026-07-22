import SwiftUI
#if os(iOS)
/// Extends the workspace table under the vertical bars on iOS 26, where the
/// scroll edge effect and `WorkspaceListScrollEdgeCoordinator`'s bar
/// registration render the App Store-style soft blur over the underlap.
///
/// SwiftUI fits a `UIViewRepresentable` inside the safe area, so without this
/// the table's frame starts below the search drawer and ends above the tab
/// bar: rows hard-clip at the chrome and no scroll edge effect can render.
/// The real UIKit bars still contribute safe area, so the table's automatic
/// content-inset adjustment keeps rows and indicators clear of the chrome,
/// and the keyboard region stays respected. Earlier releases keep the fitted
/// frame: the coordinator's registration is iOS 26-gated, and underlapping
/// without it would scroll full-opacity rows beneath legacy bars.
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
