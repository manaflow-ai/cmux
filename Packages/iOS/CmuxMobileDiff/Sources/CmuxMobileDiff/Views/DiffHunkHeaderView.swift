internal import SwiftUI

struct DiffHunkHeaderView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
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
        }
        .background(theme.hunkBackground)
    }

    private var gutterWidth: CGFloat {
        CGFloat(file.oldGutterDigits + file.newGutterDigits) * 7 + theme.gutterPadding * 4 + 18
    }
}
