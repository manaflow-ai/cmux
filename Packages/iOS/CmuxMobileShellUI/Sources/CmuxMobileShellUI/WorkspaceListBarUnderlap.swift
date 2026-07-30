import SwiftUI
#if os(iOS)
private struct WorkspaceListChromeTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var workspaceListChromeTopInset: CGFloat {
        get { self[WorkspaceListChromeTopInsetKey.self] }
        set { self[WorkspaceListChromeTopInsetKey.self] = newValue }
    }
}

/// Extends the workspace table under the vertical bars on iOS 26, where the
/// scroll edge effect and `WorkspaceListScrollEdgeCoordinator`'s bar
/// registration render the App Store-style soft blur over the underlap.
///
/// SwiftUI fits a `UIViewRepresentable` inside the safe area, so without this
/// the table's frame starts below the search drawer and ends above the tab
/// bar: rows hard-clip at the chrome and no scroll edge effect can render.
/// The pre-underlap top safe area is passed to the table as
/// `workspaceListChromeTopInset` so rows and the refresh indicator stay below
/// the chrome: ignoring the safe area also removes it from the table's
/// automatic content-inset adjustment, which UIKit uses to position the
/// `UIRefreshControl`, so without the explicit inset the pull spinner renders
/// behind the header material. Earlier releases keep the fitted frame: the
/// coordinator's registration is iOS 26-gated, and underlapping without it
/// would scroll full-opacity rows beneath legacy bars.
struct WorkspaceListBarUnderlap: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The GeometryReader must stay fitted (inside the safe area) with
            // `ignoresSafeArea` applied to the content within it. Applying
            // `ignoresSafeArea` to the GeometryReader itself expands it first,
            // and its proxy then reports zero top safe area.
            GeometryReader { proxy in
                content
                    .environment(
                        \.workspaceListChromeTopInset,
                        proxy.safeAreaInsets.top
                    )
                    .ignoresSafeArea(.container, edges: .vertical)
            }
        } else {
            content
        }
    }
}
#endif
