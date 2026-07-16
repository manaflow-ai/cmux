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
    let onClose: @MainActor @Sendable () -> Void
    @State private var path: [Int]

    init(
        branch: String,
        base: String,
        totals: ChangesTotals,
        files: [ChangedFileItem],
        listState: WorkspaceChangesListState,
        cachedDocuments: [String: FileDiffDocument],
        fontSize: Double,
        initialFileIndex: Int?,
        listActions: WorkspaceChangesListActions,
        pagerActions: WorkspaceFileDiffPagerActions,
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
        self.onClose = onClose
        _path = State(initialValue: initialFileIndex.map { [$0] } ?? [])
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
                    onSelectFile: { path.append($0) },
                    onRefresh: listActions.onRefresh,
                    onRetry: listActions.onRetry
                )
            )
            .navigationDestination(for: Int.self) { index in
                WorkspaceFileDiffPagerView(
                    files: files,
                    initialSelectedIndex: index,
                    cachedDocuments: cachedDocuments,
                    initialFontSize: fontSize,
                    actions: pagerActions
                )
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
