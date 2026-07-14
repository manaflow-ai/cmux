internal import SwiftUI

/// Renders paired old/new code cells with independent gutters and padding cells.
struct DiffSplitCodeRowView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.splitOldSide, digits: file.oldGutterDigits, isOld: true)
            Divider()
            side(row.splitNewSide, digits: file.newGutterDigits, isOld: false)
        }
    }

    private func side(_ side: DiffSplitSideSnapshot?, digits: Int, isOld: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(side?.lineNumber.map(String.init) ?? "")
                .font(.system(.caption2, design: .monospaced).monospacedDigit())
                .foregroundStyle(theme.gutterForeground)
                .frame(width: CGFloat(digits) * 7 + theme.gutterPadding * 2, alignment: .trailing)
                .padding(.vertical, 3)
                .padding(.trailing, theme.gutterPadding)
                .background(gutterBackground(side?.kind))
            Text(marker(for: side?.kind, isOld: isOld))
                .font(.system(.footnote, design: .monospaced))
                .frame(width: 16, alignment: .center)
                .padding(.vertical, 2)
                .background(gutterBackground(side?.kind))
            if let side {
                Text(attributedText(side))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                    .padding(.trailing, 6)
                    .background(codeBackground(side.kind))
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func marker(for kind: DiffRowKind?, isOld: Bool) -> String {
        switch kind {
        case .deletion: "−"
        case .addition: "+"
        case .context: " "
        default: isOld ? " " : " "
        }
    }

    private func codeBackground(_ kind: DiffRowKind) -> Color {
        switch kind {
        case .addition: theme.additionBackground
        case .deletion: theme.deletionBackground
        default: .clear
        }
    }

    private func gutterBackground(_ kind: DiffRowKind?) -> Color {
        switch kind {
        case .addition: theme.additionGutterBackground
        case .deletion: theme.deletionGutterBackground
        default: .clear
        }
    }

    private func attributedText(_ side: DiffSplitSideSnapshot) -> AttributedString {
        var value = side.highlightedText ?? AttributedString(side.text)
        let tint = side.kind == .addition ? theme.additionIntralineBackground : theme.deletionIntralineBackground
        for range in side.intralineRanges {
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
