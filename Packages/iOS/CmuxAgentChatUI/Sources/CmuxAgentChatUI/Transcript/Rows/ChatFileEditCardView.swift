import CmuxAgentChat
import SwiftUI

/// A full-width file-edit card: operation icon, file path, add/remove
/// counts, and the unified diff with per-line add/remove tinting.
public struct ChatFileEditCardView: View {
    private let edit: ChatFileEdit
    private let rowID: String
    private let onShowDetail: () -> Void

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatContentCache) private var contentCache

    private static let collapsedLineCap = 8

    /// Creates a file-edit card.
    ///
    /// - Parameters:
    ///   - edit: The file modification payload.
    ///   - rowID: The row's stable identity, for cached diff rendering.
    ///   - onShowDetail: Opens the full diff in a stable detail sheet.
    public init(edit: ChatFileEdit, rowID: String, onShowDetail: @escaping () -> Void = {}) {
        self.edit = edit
        self.rowID = rowID
        self.onShowDetail = onShowDetail
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let diff = edit.unifiedDiff, !diff.isEmpty {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(height: 0.5)
                diffBlock(diff: diff)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.terminalCardFill, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        )
        .contentShape(.rect)
        .onTapGesture(perform: onShowDetail)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            String(
                localized: "chat.detail.show.hint",
                defaultValue: "Opens a sheet with the full block content",
                bundle: .module
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: operationSymbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(edit.filePath)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.terminalCardText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            counts
            detailGlyph
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
    }

    /// SF symbol for the edit operation.
    private var operationSymbolName: String {
        switch edit.operation {
        case .edit: return "pencil"
        case .write: return "plus.square"
        case .delete: return "trash"
        }
    }

    @ViewBuilder
    private var counts: some View {
        HStack(spacing: 4) {
            if let additions = edit.additions {
                Text(verbatim: "+\(additions)")
                    .foregroundStyle(.green)
            }
            if let deletions = edit.deletions {
                Text(verbatim: "−\(deletions)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var detailGlyph: some View {
        Image(systemName: "doc.text.magnifyingglass")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func diffBlock(diff: String) -> some View {
        let lines = contentCache?.diffLines(messageID: rowID, diff: diff)
            ?? diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cap = Self.collapsedLineCap
        let visible = Array(lines.prefix(cap))
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
                if lines.count > cap {
                    Text(
                        String(
                            localized: "chat.terminal.more_lines",
                            defaultValue: "⋯ \(lines.count - cap) more lines",
                            bundle: .module
                        )
                    )
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func diffLine(_ line: String) -> some View {
        Text(verbatim: line.isEmpty ? " " : line)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(foregroundColor(for: line))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor(for: line))
            // VoiceOver can't see the +/- color tint, so name the change
            // kind. Font stays fixed: diffs render as screens (round 7).
            .accessibilityLabel(diffLineAccessibilityLabel(line))
    }

    private func diffLineAccessibilityLabel(_ line: String) -> String {
        if line.hasPrefix("+") {
            return String(localized: "chat.diff.added.accessibility",
                          defaultValue: "Added: \(line.dropFirst())", bundle: .module)
        }
        if line.hasPrefix("-") {
            return String(localized: "chat.diff.removed.accessibility",
                          defaultValue: "Removed: \(line.dropFirst())", bundle: .module)
        }
        if line.hasPrefix("@@") {
            return String(localized: "chat.diff.hunk.accessibility",
                          defaultValue: "Section: \(line)", bundle: .module)
        }
        return line
    }

    private func foregroundColor(for line: String) -> Color {
        if line.hasPrefix("@@") { return theme.terminalCardText.opacity(0.6) }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return theme.terminalCardText.opacity(0.75)
    }

    private func backgroundColor(for line: String) -> Color {
        if line.hasPrefix("@@") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.08) }
        if line.hasPrefix("-") { return .red.opacity(0.08) }
        return .clear
    }
}
