internal import SwiftUI

/// Value-only lazy list; every descendant receives snapshots and closure actions.
struct ChangesListView: View {
    let snapshot: ChangesScreenSnapshot
    let actions: ChangesScreenActions
    let renderingMode: DiffRenderingMode
    let layoutPreference: DiffLayoutPreference
    let setLayoutPreference: @MainActor @Sendable (DiffLayoutPreference) -> Void
    @Binding var scrollAnchorID: String?
    let requestNote: (@MainActor @Sendable (DiffFileSnapshot, DiffRowSnapshot, DiffNoteSelectionScope) -> Void)?
    @State private var visibleFilePath: String?
    private let rowBuilder = DiffRowBuilder()
    private let anchorResolver = DiffScrollAnchorResolver()

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

            ForEach(snapshot.files) { file in
                Section {
                    if !file.isCollapsed || file.rows.contains(where: { $0.kind == .largeDiff }) {
                        ForEach(projectedRows(file).filter { $0.kind != .fileHeader }) { row in
                            DiffRowView(file: file, row: row, actions: actions, requestNote: requestNote)
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
        .scrollPosition(id: $scrollAnchorID, anchor: .top)
        .onChange(of: scrollAnchorID, initial: true) { _, anchor in
            if let path = anchorResolver.filePath(containing: anchor, files: snapshot.files) {
                visibleFilePath = path
            }
        }
        .onChange(of: renderingMode) { _, _ in
            scrollAnchorID = anchorResolver.resolvedAnchor(
                scrollAnchorID,
                visibleFilePath: visibleFilePath,
                files: snapshot.files,
                mode: renderingMode
            )
        }
        .onChange(of: snapshot.files) { _, _ in
            if let matchedPath = anchorResolver.filePath(containing: scrollAnchorID, files: snapshot.files),
               matchedPath != scrollAnchorID {
                visibleFilePath = matchedPath
                scrollAnchorID = matchedPath
                return
            }
            guard !anchorResolver.containsVisibleAnchor(
                scrollAnchorID,
                files: snapshot.files,
                mode: renderingMode
            ), let visibleFilePath else { return }
            scrollAnchorID = visibleFilePath
        }
    }

    private func projectedRows(_ file: DiffFileSnapshot) -> [DiffRowSnapshot] {
        rowBuilder.projectedRows(file.rows, mode: renderingMode)
    }

}
