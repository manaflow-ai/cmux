import CmuxDiffModel
import CmuxMobileSupport
import SwiftUI

struct DiffReviewLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(number(line.oldLine))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(number(line.newLine))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(verbatim: marker)
                    .fontWeight(.bold)
                    .frame(width: 14, alignment: .center)
            }
            .foregroundStyle(gutterForeground)
            .padding(.horizontal, 4)
            .frame(width: 92)
            .background(gutterBackground)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(contentForeground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
            }
            .background(contentBackground)
        }
        .font(.caption.monospaced().monospacedDigit())
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("DiffReviewLine-\(line.id)")
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: "·"
        }
    }

    private var gutterForeground: Color {
        switch line.kind {
        case .addition: .green
        case .deletion: .red
        case .context: .secondary
        }
    }

    private var contentForeground: Color {
        switch line.kind {
        case .addition: .primary
        case .deletion: .primary
        case .context: .primary.opacity(0.82)
        }
    }

    private var gutterBackground: Color {
        switch line.kind {
        case .addition: .green.opacity(0.18)
        case .deletion: .red.opacity(0.18)
        case .context: Color.secondary.opacity(0.08)
        }
    }

    private var contentBackground: Color {
        switch line.kind {
        case .addition: .green.opacity(0.08)
        case .deletion: .red.opacity(0.08)
        case .context: .clear
        }
    }

    private var accessibilityLabel: String {
        switch line.kind {
        case .addition:
            return String(
                format: L10n.string(
                    "mobile.diff.lineAdditionAccessibilityFormat",
                    defaultValue: "Addition, new line %1$d, %2$@"
                ),
                line.newLine ?? 0,
                line.text
            )
        case .deletion:
            return String(
                format: L10n.string(
                    "mobile.diff.lineDeletionAccessibilityFormat",
                    defaultValue: "Deletion, old line %1$d, %2$@"
                ),
                line.oldLine ?? 0,
                line.text
            )
        case .context:
            return String(
                format: L10n.string(
                    "mobile.diff.lineContextAccessibilityFormat",
                    defaultValue: "Context, old line %1$d, new line %2$d, %3$@"
                ),
                line.oldLine ?? 0,
                line.newLine ?? 0,
                line.text
            )
        }
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}
