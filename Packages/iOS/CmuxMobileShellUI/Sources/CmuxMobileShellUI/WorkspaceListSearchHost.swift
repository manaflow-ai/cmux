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
                .toolbar(removing: .search)
                .searchable(
                    text: $searchText,
                    prompt: L10n.string(
                        "mobile.workspaces.search.placeholder",
                        defaultValue: "Search workspaces"
                    )
                )
                .searchToolbarBehavior(.minimize)
                .searchFocused($searchIsFocused)
                .toolbar {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    if let taskComposerAction {
                        ToolbarItem(placement: .bottomBar) {
                            Button(action: taskComposerAction) {
                                Image(systemName: "sparkles")
                            }
                            .accessibilityLabel(
                                L10n.string(
                                    "mobile.taskComposer.button.accessibilityLabel",
                                    defaultValue: "New Task"
                                )
                            )
                            .accessibilityHint(
                                L10n.string(
                                    "mobile.taskComposer.button.accessibilityHint",
                                    defaultValue: "Opens the task composer."
                                )
                            )
                            .accessibilityIdentifier("MobileTaskComposerButton")
                        }
                        ToolbarSpacer(.fixed, placement: .bottomBar)
                    }
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
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
