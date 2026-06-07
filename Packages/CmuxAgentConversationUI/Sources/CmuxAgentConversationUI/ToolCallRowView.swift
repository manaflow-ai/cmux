public import SwiftUI
import Foundation

/// Renders a tool call paired with its result as a collapsible row.
///
/// Collapsed, it shows the tool name and a one-line input summary. Expanded, it
/// shows the raw JSON input and the result text. `Equatable` so the body is
/// skipped when neither the snapshot nor the expanded flag changes; both inputs
/// are values, never a store reference (snapshot-boundary rule). `actions` is
/// excluded from `==` because the closures are stable.
public struct ToolCallRowView: View, Equatable {
    /// The call + result value to render.
    let snapshot: ToolCallSnapshot

    /// Whether the row is currently expanded (a value, projected by the model).
    let isExpanded: Bool

    /// Closures for row interactions (toggle, copy).
    let actions: ChatRowActions

    /// Creates a tool-call row.
    ///
    /// - Parameters:
    ///   - snapshot: The call + result value to render.
    ///   - isExpanded: Whether the row is currently expanded.
    ///   - actions: Closures for row interactions.
    public init(snapshot: ToolCallSnapshot, isExpanded: Bool, actions: ChatRowActions) {
        self.snapshot = snapshot
        self.isExpanded = isExpanded
        self.actions = actions
    }

    /// Compares the value snapshot and expanded flag; closures are excluded.
    nonisolated public static func == (lhs: ToolCallRowView, rhs: ToolCallRowView) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.isExpanded == rhs.isExpanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                actions.toggleToolCall(snapshot.callID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: snapshot.isError ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(snapshot.isError ? Color.red : Color.secondary)
                    Text(snapshot.name)
                        .font(.caption.weight(.semibold))
                    if let summary = snapshot.inputSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if snapshot.resultText == nil {
                        Text(pendingLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(snapshot.isError ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2))
        )
    }

    /// The expanded body: raw input JSON and the result text.
    @ViewBuilder
    private var expandedContent: some View {
        if !snapshot.inputJSON.isEmpty {
            Text(inputLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(snapshot.inputJSON)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let resultText = snapshot.resultText {
            Text(resultLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(snapshot.isError ? Color.red : Color.secondary)
            Text(resultText.isEmpty ? emptyResultLabel : resultText)
                .font(.caption.monospaced())
                .foregroundStyle(snapshot.isError ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copyResultLabel) {
                actions.copyText(resultText)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(resultText.isEmpty)
        }
    }

    private var pendingLabel: String {
        String(localized: "agentChat.tool.pending", defaultValue: "running…", bundle: .module)
    }

    private var inputLabel: String {
        String(localized: "agentChat.tool.input", defaultValue: "Input", bundle: .module)
    }

    private var resultLabel: String {
        String(localized: "agentChat.tool.result", defaultValue: "Result", bundle: .module)
    }

    private var emptyResultLabel: String {
        String(localized: "agentChat.tool.emptyResult", defaultValue: "(no output)", bundle: .module)
    }

    private var copyResultLabel: String {
        String(localized: "agentChat.tool.copyResult", defaultValue: "Copy result", bundle: .module)
    }
}
