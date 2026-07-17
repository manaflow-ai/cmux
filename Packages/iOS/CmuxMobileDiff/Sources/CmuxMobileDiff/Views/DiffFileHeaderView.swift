internal import SwiftUI

struct DiffFileHeaderView: View {
    let file: DiffFileSnapshot
    let actions: ChangesScreenActions
    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Button { actions.toggleFile(file.path) } label: {
                Image(systemName: file.isCollapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 18, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.isCollapsed ? expandFileText : collapseFileText)

            Text(displayPath)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(file.isViewed ? .secondary : .primary)
            Spacer(minLength: 4)
            Text("+\(file.additions)")
                .foregroundStyle(.green)
                .font(.caption.monospacedDigit())
            Text("−\(file.deletions)")
                .foregroundStyle(.red)
                .font(.caption.monospacedDigit())
            Button { actions.toggleViewed(file.path) } label: {
                Image(systemName: file.isViewed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(file.isViewed ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "diff.file.viewed", defaultValue: "Viewed", bundle: .module))
            Menu {
                Button {
                    actions.copyPath(file.path)
                } label: {
                    Label(String(localized: "diff.file.copyPath", defaultValue: "Copy path", bundle: .module), systemImage: "doc.on.doc")
                }
                Button(file.isCollapsed ? expandFileText : collapseFileText) {
                    actions.toggleFile(file.path)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 28)
            }
            .accessibilityLabel(String(localized: "diff.file.options", defaultValue: "File options", bundle: .module))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 0.5) }
        .textCase(nil)
    }

    private var displayPath: String {
        guard let oldPath = file.oldPath, oldPath != file.path else { return file.path }
        return "\(oldPath) → \(file.path)"
    }

    private var expandFileText: String {
        String(localized: "diff.file.expand", defaultValue: "Expand file", bundle: .module)
    }

    private var collapseFileText: String {
        String(localized: "diff.file.collapse", defaultValue: "Collapse file", bundle: .module)
    }
}
