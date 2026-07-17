internal import SwiftUI

struct DiffNoNewlineRowView: View {
    let file: DiffFileSnapshot
    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text("\\")
                .font(.system(.caption2, design: .monospaced))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
            Text(String(localized: "diff.row.noNewline", defaultValue: "No newline at end of file", bundle: .module))
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 3)
    }

    private var gutterWidth: CGFloat {
        CGFloat(file.oldGutterDigits + file.newGutterDigits) * 7 + theme.gutterPadding * 4 + 18
    }
}
