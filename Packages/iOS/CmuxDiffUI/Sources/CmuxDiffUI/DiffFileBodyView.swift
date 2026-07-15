import SwiftUI

struct DiffFileBodyView: View {
    let snapshot: DiffFileSectionSnapshot
    let renderMode: DiffRenderMode
    let actions: DiffContinuousActions

    var body: some View {
        Group {
            switch snapshot.state.file.content {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(loadingLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .onAppear {
                    actions.loadFile(snapshot.state.file.summary.path, false)
                }
            case .binary:
                DiffPlaceholderRow(kind: .binary, action: {})
            case .large:
                DiffPlaceholderRow(kind: .large) {
                    actions.loadFile(snapshot.state.file.summary.path, true)
                }
            case .renameOnly:
                DiffPlaceholderRow(kind: .renameOnly, action: {})
            case let .failed(message):
                DiffPlaceholderRow(kind: .failed(message)) {
                    actions.loadFile(snapshot.state.file.summary.path, false)
                }
            case .loaded:
                if renderMode == .unified {
                    ForEach(snapshot.state.rows) { row in
                        DiffUnifiedRowView(
                            row: row,
                            highlighted: snapshot.highlights[row.id],
                            expand: { direction in
                                actions.expandContext(DiffContextExpansionRequest(
                                    path: snapshot.state.file.summary.path,
                                    hunkIndex: row.hunkIndex,
                                    direction: direction
                                ))
                            }
                        )
                    }
                } else {
                    ForEach(snapshot.state.splitRows) { row in
                        DiffSplitRowView(
                            row: row,
                            highlights: snapshot.highlights,
                            expand: { direction in
                                actions.expandContext(DiffContextExpansionRequest(
                                    path: snapshot.state.file.summary.path,
                                    hunkIndex: row.spanning?.hunkIndex
                                        ?? row.old?.hunkIndex
                                        ?? row.new?.hunkIndex
                                        ?? 0,
                                    direction: direction
                                ))
                            }
                        )
                    }
                }
            }
        }
    }

    private var loadingLabel: String {
        DiffLocalized().string("diff.state.loadingFile", defaultValue: "Loading file diff…")
    }
}
