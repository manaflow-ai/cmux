import CmuxMobileSupport
import SwiftUI

/// Owns workspace search state above list snapshots that are replaced during
/// refresh. The shell owns the query so it survives those replacements.
@MainActor
struct WorkspaceListSearchHost<Content: View>: View {
    @Binding private var searchText: String
    @FocusState private var searchIsFocused: Bool
    private let taskComposerAction: (() -> Void)?
    private let content: (String) -> Content

    init(
        searchText: Binding<String>,
        taskComposerAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        _searchText = searchText
        self.taskComposerAction = taskComposerAction
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
                // The explicit navigationBarDrawer placement and focus bridge
                // used by newer shells can wedge iOS 18's first layout pass.
                // The default placement keeps native search available without
                // that UIKit feedback path.
                .searchable(text: $searchText)
        }
    }
    #endif
}
