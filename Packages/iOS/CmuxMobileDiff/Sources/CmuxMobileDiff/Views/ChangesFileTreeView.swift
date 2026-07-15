internal import SwiftUI

/// Shared collapsible file tree used by compact navigation and iPad sidebars.
struct ChangesFileTreeView: View {
    let snapshot: ChangesScreenSnapshot
    let actions: ChangesScreenActions
    let layoutPreference: DiffLayoutPreference
    let setLayoutPreference: @MainActor @Sendable (DiffLayoutPreference) -> Void
    let selectFile: @MainActor @Sendable (String) -> Void
    @State private var collapsedDirectoryIDs: Set<String> = []
    private let projectionBuilder = FileTreeProjectionBuilder()

    var body: some View {
        List {
            Section {
                if snapshot.isLoadingSummary {
                    ChangesSkeletonView()
                } else if let error = snapshot.error {
                    ChangesErrorBanner(
                        error: error,
                        retry: actions.retrySummary,
                        useWorkingTree: { actions.selectBase(.workingTree) }
                    )
                } else if let totals = snapshot.totals {
                    ChangesSummaryHeader(
                        totals: totals,
                        viewedCount: snapshot.viewedCount,
                        ignoresWhitespace: snapshot.ignoresWhitespace,
                        baseKind: snapshot.baseKind,
                        layoutPreference: layoutPreference,
                        setLayoutPreference: setLayoutPreference,
                        actions: actions
                    )
                }
            }
            .listRowInsets(EdgeInsets())

            ForEach(visibleRows) { row in
                FileTreeRowView(
                    row: row,
                    selectFile: selectFile,
                    toggleDirectory: toggleDirectory
                )
                .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
    }

    private var visibleRows: [FileTreeRowSnapshot] {
        projectionBuilder.rows(
            roots: snapshot.fileTree,
            collapsedDirectoryIDs: collapsedDirectoryIDs
        )
    }

    private func toggleDirectory(_ id: String) {
        if collapsedDirectoryIDs.contains(id) {
            collapsedDirectoryIDs.remove(id)
        } else {
            collapsedDirectoryIDs.insert(id)
        }
    }
}
