import SwiftUI

/// Owns the native search controller above workspace snapshots that are replaced
/// during refresh. Stable query and focus ownership survive live row snapshots,
/// while an explicit navigation-bar drawer keeps search at the top on iOS 26.
@MainActor
struct WorkspaceListSearchHost<Content: View>: View {
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool
    private let content: (String) -> Content

    init(@ViewBuilder content: @escaping (String) -> Content) {
        self.content = content
    }

    var body: some View {
        #if os(iOS)
        content(searchText)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always)
            )
            .searchFocused($searchIsFocused)
        #else
        content(searchText)
            .searchable(text: $searchText)
            .searchFocused($searchIsFocused)
        #endif
    }
}
