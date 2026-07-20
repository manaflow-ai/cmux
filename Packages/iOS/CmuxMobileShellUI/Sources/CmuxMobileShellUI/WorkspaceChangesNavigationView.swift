#if os(iOS)
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
    @Binding var path: [WorkspaceChangesNavigationRoute]
    let onClose: @MainActor @Sendable () -> Void

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
        _path = path
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
        .accessibilityIdentifier("MobileChangesSheet")
    }
}
#endif
