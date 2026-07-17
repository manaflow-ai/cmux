import SwiftUI

struct DiffFileListRow: View {
    let state: DiffFilePresentationState
    let toggleViewed: @MainActor () -> Void
    let toggleCollapsed: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DiffStatusBadge(status: state.file.summary.status)
            Button(action: toggleCollapsed) {
                DiffPathLabel(
                    path: state.file.summary.path,
                    oldPath: state.file.summary.oldPath,
                    showRename: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 5) {
                Text("+\(state.file.summary.additions)")
                    .foregroundStyle(.green)
                Text("−\(state.file.summary.deletions)")
                    .foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            DiffViewedButton(isViewed: state.isViewed, action: toggleViewed)
        }
        .opacity(state.isViewed ? 0.52 : 1)
        .padding(.vertical, 2)
    }
}
