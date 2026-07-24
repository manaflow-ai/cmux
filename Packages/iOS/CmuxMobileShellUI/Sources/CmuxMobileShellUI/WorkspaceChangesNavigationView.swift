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
    let cachedPresentations: [String: FileDiffPresentation]
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
        cachedPresentations: [String: FileDiffPresentation],
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
        self.cachedPresentations = cachedPresentations
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
                    onSelectFile: { index in
                        guard files.indices.contains(index) else { return }
                        path.append(.diff(files[index].path))
                    },
                    onRefresh: listActions.onRefresh,
                    onRetry: listActions.onRetry
                )
            )
            .navigationDestination(for: WorkspaceChangesNavigationRoute.self) { route in
                switch route {
                case .diff(let filePath):
                    if let index = files.firstIndex(where: { $0.path == filePath }) {
                    WorkspaceFileDiffPagerView(
                        files: files,
                        initialSelectedIndex: index,
                        cachedPresentations: cachedPresentations,
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
                    } else {
                        // Fail closed: the file left the changed set (refresh
                        // while pushed) rather than showing a neighbor's diff.
                        ContentUnavailableView {
                            Label(
                                String(
                                    localized: "workspace.changes.file_missing",
                                    defaultValue: "File no longer changed",
                                    bundle: .module
                                ),
                                systemImage: "doc.questionmark"
                            )
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
