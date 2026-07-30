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
            // A `.bottomBar` toolbar item cannot host New Task here: the
            // TabView's search-role tab renders its pill in the same
            // bottom-trailing slot and the two stack on top of each other.
            // Mount the shared button in the bottom safe-area bar instead,
            // above the tab-bar chrome the system owns.
            content(searchText)
                .safeAreaBar(edge: .bottom, alignment: .trailing, spacing: 0) {
                    if let taskComposerAction {
                        TaskComposerButton(action: taskComposerAction)
                            .padding(.trailing, 20)
                            .padding(.bottom, 6)
                    }
                }
        } else {
            content(searchText)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always)
                )
                .searchFocused($searchIsFocused)
                .overlay(alignment: .bottomTrailing) {
                    if let taskComposerAction {
                        TaskComposerButton(action: taskComposerAction)
                            .padding(.trailing, 20)
                            .padding(.bottom, 6)
                    }
                }
        }
    }
    #endif
}
