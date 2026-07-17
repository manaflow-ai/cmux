import SwiftUI

struct DiffCodeText: View {
    @Environment(\.diffTheme) private var theme
    let row: DiffRowSnapshot
    let highlighted: HighlightedCode?

    var body: some View {
        HStack(spacing: 0) {
            if !row.intralineSpans.isEmpty {
                ForEach(Array(row.intralineSpans.enumerated()), id: \.offset) { _, span in
                    Text(span.text)
                        .background(span.isEmphasized ? emphasisFill : Color.clear)
                }
            } else if let highlighted, !highlighted.spans.isEmpty {
                ForEach(Array(highlighted.spans.enumerated()), id: \.offset) { _, span in
                    Text(span.text)
                        .foregroundStyle(span.foreground?.swiftUIColor ?? Color.primary)
                }
            } else {
                Text(row.text.isEmpty ? " " : row.text)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize(horizontal: true, vertical: false)
        .textSelection(.enabled)
    }

    private var emphasisFill: Color {
        row.kind == .deletion ? theme.deletionEmphasisFill : theme.additionEmphasisFill
    }
}
