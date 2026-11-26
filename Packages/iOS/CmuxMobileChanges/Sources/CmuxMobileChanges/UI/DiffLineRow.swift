import SwiftUI

struct DiffLineRow: View {
    let line: DiffLine
    let hunkCopyText: String
    let gutterWidth: CGFloat
    let fontSize: Double
    let theme: ChangesTheme
    let onCopy: @MainActor @Sendable (String) -> Void

    var body: some View {
        Group {
            if line.kind == .noNewlineMarker {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .accessibilityHidden(true)
                    Text(String(
                        localized: "changes.diff.no_newline_marker",
                        defaultValue: "No newline at end of file",
                        bundle: .module
                    ))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            } else if line.kind == .hunkHeader {
                Text(line.text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(theme.hunkHeaderText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.hunkHeaderBackground)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    gutterText(line.oldNumber)
                    gutterText(line.newNumber)
                    Text(marker)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(markerColor)
                        .frame(width: 12, alignment: .center)
                    Text(line.attributedCode(emphasisColor: emphasisColor))
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 3)
                }
                .padding(.vertical, theme.rowVerticalPadding)
                .background(rowBackground)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if line.kind != .noNewlineMarker {
                Button(String(localized: "changes.copy.line", defaultValue: "Copy Line", bundle: .module)) {
                    onCopy(line.text)
                }
                if !hunkCopyText.isEmpty {
                    Button(String(localized: "changes.copy.hunk", defaultValue: "Copy Hunk", bundle: .module)) {
                        onCopy(hunkCopyText)
                    }
                }
            }
        }
    }

    private func gutterText(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: fontSize, design: .monospaced).monospacedDigit())
            .foregroundStyle(theme.gutterText)
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 3)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(theme.gutterSeparator)
                    .frame(width: 0.5)
            }
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .removal: "−"
        case .context, .hunkHeader, .noNewlineMarker: ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: theme.addedStatus
        case .removal: theme.deletedStatus
        case .context, .hunkHeader, .noNewlineMarker: .secondary
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .addition: theme.additionBackground
        case .removal: theme.removalBackground
        case .context, .hunkHeader, .noNewlineMarker: .clear
        }
    }

    private var emphasisColor: Color {
        line.kind == .addition ? theme.additionEmphasis : theme.removalEmphasis
    }
}
