import SwiftUI

struct DiffFileSectionHeader: View {
    let state: DiffFilePresentationState
    let toggleCollapsed: @MainActor () -> Void
    let toggleViewed: @MainActor () -> Void
    let copyPath: @MainActor () -> Void
    let collapseAll: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleCollapsed) {
                Image(systemName: state.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.bold())
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isCollapsed ? expandFileLabel : collapseFileLabel)
            DiffPathLabel(
                path: state.file.summary.path,
                oldPath: state.file.summary.oldPath,
                showRename: true
            )
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Text("+\(state.file.summary.additions)").foregroundStyle(.green)
                Text("−\(state.file.summary.deletions)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            DiffViewedButton(isViewed: state.isViewed, action: toggleViewed)
            Menu {
                Button(copyPathLabel, systemImage: "doc.on.doc", action: copyPath)
                Button(collapseAllLabel, systemImage: "rectangle.compress.vertical", action: collapseAll)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 28)
            }
            .accessibilityLabel(moreLabel)
        }
        .opacity(state.isViewed ? 0.58 : 1)
        .padding(.vertical, 4)
        .background(.background)
    }

    private var copyPathLabel: String {
        DiffLocalized().string("diff.action.copyPath", defaultValue: "Copy path")
    }

    private var collapseAllLabel: String {
        DiffLocalized().string("diff.action.collapseAll", defaultValue: "Collapse all")
    }

    private var moreLabel: String {
        DiffLocalized().string("diff.action.fileMenu", defaultValue: "File options")
    }

    private var expandFileLabel: String {
        DiffLocalized().string("diff.action.expandFile", defaultValue: "Expand file")
    }

    private var collapseFileLabel: String {
        DiffLocalized().string("diff.action.collapseFile", defaultValue: "Collapse file")
    }
}
