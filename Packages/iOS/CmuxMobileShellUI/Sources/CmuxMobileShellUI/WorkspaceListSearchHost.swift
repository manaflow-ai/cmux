import SwiftUI

/// Owns workspace search state above list snapshots that are replaced during
/// refresh. The shell owns the query so it survives those replacements.
@MainActor
struct WorkspaceListSearchHost<Content: View>: View {
    @Binding private var searchText: String
    @FocusState private var searchIsFocused: Bool
    private let content: (String) -> Content

    init(
        searchText: Binding<String>,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        _searchText = searchText
        self.content = content
    }

    var body: some View {
        #if os(iOS)
        iOSContent
        #else
        content(searchText)
            .searchable(text: $searchText)
            .searchFocused($searchIsFocused)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSContent: some View {
        if #available(iOS 26.0, *) {
            content(searchText)
        } else {
            content(searchText)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always)
                )
                .searchFocused($searchIsFocused)
        }
    }
    #endif
}
