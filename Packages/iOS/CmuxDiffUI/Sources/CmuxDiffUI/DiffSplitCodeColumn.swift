import SwiftUI

struct DiffSplitCodeColumn: View {
    @Environment(\.diffTheme) private var theme
    let row: DiffRowSnapshot?
    let highlighted: HighlightedCode?
    let isOldSide: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(lineNumber)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.gutterForeground)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 4)
            Text(marker)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 14)
            if let row {
                DiffCodeText(row: row, highlighted: highlighted)
            } else {
                Spacer(minLength: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .clipped()
    }

    private var lineNumber: String {
        guard let row else { return "" }
        return (isOldSide ? row.oldLine : row.newLine).map(String.init) ?? ""
    }

    private var marker: String {
        guard let row else { return "" }
        if row.kind == .deletion { return "−" }
        if row.kind == .addition { return "+" }
        return " "
    }

    private var fill: Color {
        guard let row else { return .clear }
        if row.kind == .deletion { return theme.deletionFill }
        if row.kind == .addition { return theme.additionFill }
        return .clear
    }
}
