internal import SwiftUI

/// Value-only lazy list; every descendant receives snapshots and closure actions.
struct ChangesListView: View {
    let snapshot: ChangesScreenSnapshot
    let actions: ChangesScreenActions
    let scrollToPath: String?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    if snapshot.isLoadingSummary {
                        ChangesSkeletonView()
                    } else if let error = snapshot.error {
                        ChangesErrorBanner(error: error, retry: actions.retrySummary)
                    } else if let totals = snapshot.totals {
                        ChangesSummaryHeader(
                            totals: totals,
                            viewedCount: snapshot.viewedCount,
                            ignoresWhitespace: snapshot.ignoresWhitespace,
                            actions: actions
                        )
                    }
                }
                .listRowInsets(EdgeInsets())

                ForEach(snapshot.files) { file in
                    Section {
                        if !file.isCollapsed || file.rows.contains(where: { $0.kind == .largeDiff }) {
                            ForEach(file.rows.filter { $0.kind != .fileHeader }) { row in
                                DiffRowView(file: file, row: row, actions: actions)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                            }
                        }
                    } header: {
                        DiffFileHeaderView(file: file, actions: actions)
                            .id(file.path)
                    }
                }
            }
            .listStyle(.plain)
            .task(id: snapshot.files.map(\.path)) {
                guard let scrollToPath,
                      snapshot.files.contains(where: { $0.path == scrollToPath }) else { return }
                proxy.scrollTo(scrollToPath, anchor: .top)
            }
        }
    }
}
