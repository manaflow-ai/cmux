#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Keeps the compact tab bar and its root navigation chrome in one hierarchy.
/// The tab contents still keep their own navigation paths, but they no longer
/// compete to install the root toolbar as selection changes.
struct MobilePrimaryTabNavigationHost<Content: View, Toolbar: ToolbarContent>: View {
    let content: Content
    let toolbar: Toolbar
    let toolbarVisibility: Visibility
    let tabBarVisibility: Visibility

    init(
        toolbarVisibility: Visibility,
        tabBarVisibility: Visibility = .automatic,
        @ToolbarContentBuilder toolbar: () -> Toolbar,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.toolbar = toolbar()
        self.toolbarVisibility = toolbarVisibility
        self.tabBarVisibility = tabBarVisibility
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    toolbar
                }
                .mobileToolbarVisibility(toolbarVisibility, for: .navigationBar)
                .mobileToolbarVisibility(tabBarVisibility, for: .tabBar)
        }
    }
}
#endif
