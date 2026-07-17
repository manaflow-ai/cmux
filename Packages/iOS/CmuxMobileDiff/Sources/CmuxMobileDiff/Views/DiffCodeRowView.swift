internal import SwiftUI

struct DiffCodeRowView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(row.oldLineNumber, digits: file.oldGutterDigits)
            gutter(row.newLineNumber, digits: file.newGutterDigits)
            Text(row.marker)
                .font(.system(.footnote, design: .monospaced))
                .frame(width: 18, alignment: .center)
                .padding(.vertical, 2)
                .background(gutterBackground)
            Text(attributedText)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .padding(.trailing, 8)
                .background(codeBackground)
        }
    }

    private func gutter(_ number: Int?, digits: Int) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced).monospacedDigit())
            .foregroundStyle(theme.gutterForeground)
            .frame(width: CGFloat(digits) * 7 + theme.gutterPadding * 2, alignment: .trailing)
            .padding(.vertical, 3)
            .padding(.trailing, theme.gutterPadding)
            .background(gutterBackground)
    }

    private var codeBackground: Color {
        switch row.kind {
        case .addition: theme.additionBackground
        case .deletion: theme.deletionBackground
        default: .clear
        }
    }

    private var gutterBackground: Color {
        switch row.kind {
        case .addition: theme.additionGutterBackground
        case .deletion: theme.deletionGutterBackground
        default: .clear
        }
    }

    private var attributedText: AttributedString {
        var value = row.highlightedText ?? AttributedString(row.text)
        let tint = row.kind == .addition ? theme.additionIntralineBackground : theme.deletionIntralineBackground
        for range in row.intralineRanges {
            guard range.lowerBound >= 0,
                  range.upperBound <= value.characters.count,
                  range.lowerBound < range.upperBound else { continue }
            let lower = value.characters.index(value.startIndex, offsetBy: range.lowerBound)
            let upper = value.characters.index(value.startIndex, offsetBy: range.upperBound)
            value[lower..<upper].backgroundColor = tint
        }
        return value
    }
}
