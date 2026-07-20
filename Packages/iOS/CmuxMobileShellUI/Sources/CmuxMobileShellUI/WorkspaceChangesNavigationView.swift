#if os(iOS)
import CmuxAgentChatUI
import CmuxMobileChanges
import SwiftUI

struct WorkspaceChangesNavigationView: View {
    let branch: String
    let base: String
    let totals: ChangesTotals
    let files: [ChangedFileItem]
    let listState: WorkspaceChangesListState
    let cachedDocuments: [String: FileDiffDocument]
    let fontSize: Double
    let listActions: WorkspaceChangesListActions
    let pagerActions: WorkspaceFileDiffPagerActions
    let inlineActionHost: ChatArtifactInlineActionHost?
    @Binding var path: [WorkspaceChangesNavigationRoute]
    let onClose: @MainActor @Sendable () -> Void
    @State private var inlineActionDescriptor: ChatArtifactInlineActionDescriptor?

    init(
        branch: String,
        base: String,
        totals: ChangesTotals,
        files: [ChangedFileItem],
        listState: WorkspaceChangesListState,
        cachedDocuments: [String: FileDiffDocument],
        fontSize: Double,
        listActions: WorkspaceChangesListActions,
        pagerActions: WorkspaceFileDiffPagerActions,
        inlineActionHost: ChatArtifactInlineActionHost? = nil,
        path: Binding<[WorkspaceChangesNavigationRoute]>,
        onClose: @escaping @MainActor @Sendable () -> Void
    ) {
        self.branch = branch
        self.base = base
        self.totals = totals
        self.files = files
        self.listState = listState
        self.cachedDocuments = cachedDocuments
        self.fontSize = fontSize
        self.listActions = listActions
        self.pagerActions = pagerActions
        self.inlineActionHost = inlineActionHost
        _path = path
        _inlineActionDescriptor = State(initialValue: nil)
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack(path: $path) {
            WorkspaceChangesListView(
                branch: branch,
                base: base,
                totals: totals,
                files: files,
                state: listState,
                actions: WorkspaceChangesListActions(
                    onSelectFile: { path.append(.diff($0)) },
                    onRefresh: listActions.onRefresh,
                    onRetry: listActions.onRetry
                )
            )
            .navigationDestination(for: WorkspaceChangesNavigationRoute.self) { route in
                switch route {
                case .diff(let index):
                    WorkspaceFileDiffPagerView(
                        files: files,
                        initialSelectedIndex: index,
                        cachedDocuments: cachedDocuments,
                        initialFontSize: fontSize,
                        actions: pagerActions
                    )
                    // A pushed destination owns its own navigation bar, so the
                    // conditional preview actions must be declared here rather
                    // than on the root list screen's toolbar.
                    .toolbar {
                        if let inlineActionDescriptor,
                           let inlineActionHost {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                ForEach(inlineActionDescriptor.actions, id: \.self) { action in
                                    Button {
                                        inlineActionHost.perform(
                                            action,
                                            descriptorID: inlineActionDescriptor.id
                                        )
                                    } label: {
                                        Label(
                                            action.localizedTitle,
                                            systemImage: action.systemImage
                                        )
                                        .labelStyle(.iconOnly)
                                    }
                                    .disabled(inlineActionDescriptor.isRunning)
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(String(
                        localized: "workspace.changes.title",
                        defaultValue: "Changes",
                        bundle: .module
                    ))
                    .font(.headline)
                }
                if path.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(String(
                            localized: "workspace.changes.close",
                            defaultValue: "Close",
                            bundle: .module
                        ))
                        .accessibilityIdentifier("MobileChangesClose")
                    }
                }
            }
        }
        .onPreferenceChange(ChatArtifactInlineActionsPreferenceKey.self) { descriptor in
            inlineActionDescriptor = descriptor
        }
        .accessibilityIdentifier("MobileChangesSheet")
    }
}
#endif
