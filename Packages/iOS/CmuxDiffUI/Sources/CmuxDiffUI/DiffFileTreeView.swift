import SwiftUI

struct DiffFileTreeView: View {
    @State private var collapsedPaths: Set<String> = []

    let nodes: [DiffTreeNode]
    let files: [DiffFilePresentationState]
    let selectFile: @MainActor (String) -> Void
    let refresh: @MainActor @Sendable () async -> Void

    var body: some View {
        let rows = DiffTreeProjection().rows(
            nodes: nodes,
            files: files,
            collapsedPaths: collapsedPaths
        )
        List {
            DiffTreeProgressView(
                viewedCount: files.count(where: \.isViewed),
                fileCount: files.count
            )
            .listRowSeparator(.hidden)

            ForEach(rows) { row in
                DiffTreeRowView(row: row) {
                    switch row.kind {
                    case .directory:
                        if collapsedPaths.contains(row.path) {
                            collapsedPaths.remove(row.path)
                        } else {
                            collapsedPaths.insert(row.path)
                        }
                    case .file:
                        selectFile(row.path)
                    }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        #if os(iOS)
        .listRowSpacing(0)
        #endif
        .refreshable {
            await refresh()
        }
    }
}
