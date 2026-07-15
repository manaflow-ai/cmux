import SwiftUI

struct DiffUnifiedRowView: View {
    @Environment(\.diffTheme) private var theme
    let row: DiffRowSnapshot
    let highlighted: HighlightedCode?
    let expand: @MainActor (DiffContextExpansionRequest.Direction) -> Void

    var body: some View {
        if row.kind == .hunkHeader {
            DiffHunkHeaderView(row: row, expand: expand)
        } else if row.kind == .noNewline {
            Text(noNewlineLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    gutter(row.oldLine)
                    gutter(row.newLine)
                    Text(marker)
                        .frame(width: 18)
                        .font(.system(size: 12, design: .monospaced))
                    DiffCodeText(row: row, highlighted: highlighted)
                        .padding(.trailing, 10)
                }
                .frame(minWidth: 360, alignment: .leading)
            }
            .background(rowFill)
        }
    }

    private func gutter(_ line: Int?) -> some View {
        Text(line.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.gutterForeground)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 6)
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.hairline).frame(width: 0.5)
            }
    }

    private var marker: String {
        switch row.kind {
        case .addition: "+"
        case .deletion: "−"
        default: " "
        }
    }

    private var rowFill: Color {
        switch row.kind {
        case .addition: theme.additionFill
        case .deletion: theme.deletionFill
        default: .clear
        }
    }

    private var noNewlineLabel: String {
        DiffLocalized().string("diff.row.noNewline", defaultValue: "No newline at end of file")
    }
}
