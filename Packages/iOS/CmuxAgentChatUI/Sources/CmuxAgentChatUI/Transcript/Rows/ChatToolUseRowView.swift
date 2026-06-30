import CmuxAgentChat
import SwiftUI

/// A compact tool-invocation row: tool icon, one-line summary, and a status
/// glyph. Tap expands the full input and result inside a hairline card.
public struct ChatToolUseRowView: View {
    private let toolUse: ChatToolUse
    private let rowID: String
    private let isExpanded: Bool
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    private static let collapsedInputLineCap = 12
    private static let expandedOutputLineCap = 16

    /// Creates a tool-use row.
    ///
    /// - Parameters:
    ///   - toolUse: The invocation payload.
    ///   - rowID: The row's stable identity, for expansion toggling.
    ///   - isExpanded: Whether the detail card is showing.
    ///   - actions: Row action bundle.
    public init(toolUse: ChatToolUse, rowID: String, isExpanded: Bool, actions: ChatRowActions) {
        self.toolUse = toolUse
        self.rowID = rowID
        self.isExpanded = isExpanded
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                actions.toggleExpanded(rowID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(toolUse.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusGlyph
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                isExpanded
                    ? String(
                        localized: "chat.row.expanded.accessibility",
                        defaultValue: "Expanded",
                        bundle: .module
                    )
                    : String(
                        localized: "chat.row.collapsed.accessibility",
                        defaultValue: "Collapsed",
                        bundle: .module
                    )
            )
            .accessibilityHint(
                isExpanded
                    ? String(
                        localized: "chat.row.collapse.hint",
                        defaultValue: "Double tap to collapse",
                        bundle: .module
                    )
                    : String(
                        localized: "chat.row.expand.hint",
                        defaultValue: "Double tap to expand",
                        bundle: .module
                    )
            )
            if isExpanded {
                detailCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// SF symbol for the tool, keyed off its machine name.
    private var symbolName: String {
        let name = toolUse.toolName.lowercased()
        if name == "read" { return "doc.text" }
        if name.contains("grep") || name.contains("glob") || name.contains("search") {
            return "magnifyingglass"
        }
        if name.contains("webfetch") || name.contains("websearch") { return "globe" }
        if name.contains("task") || name.contains("agent") { return "person.2" }
        return "gearshape"
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch toolUse.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityLabel(
                    String(
                        localized: "chat.tool.succeeded.accessibility",
                        defaultValue: "Succeeded",
                        bundle: .module
                    )
                )
        case .failed:
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityLabel(
                    String(
                        localized: "chat.tool.failed.accessibility",
                        defaultValue: "Failed",
                        bundle: .module
                    )
                )
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let input = toolUse.inputDetail, !input.isEmpty {
                clampedText(input, lineCap: Self.collapsedInputLineCap)
            }
            if let output = toolUse.output, !output.isEmpty {
                clampedText(output, lineCap: Self.expandedOutputLineCap)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.terminalCardFill, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        )
    }

    /// Renders `text` capped at `lineCap` lines, appending a truncation
    /// note when lines were dropped.
    @ViewBuilder
    private func clampedText(_ text: String, lineCap: Int) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        Text(lines.prefix(lineCap).joined(separator: "\n"))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(theme.terminalCardText)
            .textSelection(.enabled)
        if lines.count > lineCap {
            Text(String(localized: "chat.tool.truncated", defaultValue: "⋯ truncated", bundle: .module))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
