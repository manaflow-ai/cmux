import SwiftUI

/// Owns the native search controller above workspace snapshots that are replaced
/// during refresh. Stable identity preserves the query, while an explicit
/// navigation-bar drawer keeps the search location at the top on iOS 26.
@MainActor
struct WorkspaceListSearchHost<Content: View>: View {
    @State private var searchText = ""
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
        #else
        content(searchText)
            .searchable(text: $searchText)
        #endif
    }
}
