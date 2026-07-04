import CmuxAgentChat
import SwiftUI

/// A compact tool-invocation row: tool icon, one-line summary, and a status
/// glyph.
public struct ChatToolUseRowView: View {
    private let toolUse: ChatToolUse
    private let onShowDetail: () -> Void

    /// Creates a tool-use row.
    ///
    /// - Parameters:
    ///   - toolUse: The invocation payload.
    ///   - onShowDetail: Opens the full tool input/output in a detail sheet.
    public init(toolUse: ChatToolUse, onShowDetail: @escaping () -> Void = {}) {
        self.toolUse = toolUse
        self.onShowDetail = onShowDetail
    }

    public var body: some View {
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
            detailGlyph
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var detailGlyph: some View {
        Image(systemName: "doc.text.magnifyingglass")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
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
}
