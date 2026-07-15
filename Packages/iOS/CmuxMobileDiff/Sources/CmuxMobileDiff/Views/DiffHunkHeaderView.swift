internal import SwiftUI

struct DiffHunkHeaderView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    let requestNote: (@MainActor @Sendable (DiffFileSnapshot, DiffRowSnapshot, DiffNoteSelectionScope) -> Void)?
    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: gutterWidth)
            Text(row.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            if let requestNote {
                Button {
                    requestNote(file, row, .hunk)
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .accessibilityLabel(String(
                    localized: "diff.note.hunkAction",
                    defaultValue: "Add note about hunk",
                    bundle: .module
                ))
            }
        }
        .background(theme.hunkBackground)
    }

    private var gutterWidth: CGFloat {
        CGFloat(file.oldGutterDigits + file.newGutterDigits) * 7 + theme.gutterPadding * 4 + 18
    }
}
