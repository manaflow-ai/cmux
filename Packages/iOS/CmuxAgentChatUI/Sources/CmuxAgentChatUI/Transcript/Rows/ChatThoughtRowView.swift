import CmuxAgentChat
import SwiftUI

/// A collapsed agent reasoning block: a small "Thought" caption that
/// expands in place to the full reasoning text on tap.
public struct ChatThoughtRowView: View {
    private let thought: ChatThought
    private let rowID: String
    private let isExpanded: Bool
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Creates a thought row.
    ///
    /// - Parameters:
    ///   - thought: The reasoning payload.
    ///   - rowID: The row's stable identity, for expansion toggling.
    ///   - isExpanded: Whether the full text is showing.
    ///   - actions: Row action bundle.
    public init(thought: ChatThought, rowID: String, isExpanded: Bool, actions: ChatRowActions) {
        self.thought = thought
        self.rowID = rowID
        self.isExpanded = isExpanded
        self.actions = actions
    }

    public var body: some View {
        Button {
            actions.toggleExpanded(rowID)
        } label: {
            HStack(spacing: 0) {
                if isExpanded {
                    expandedContent
                } else {
                    collapsedContent
                }
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var collapsedContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "brain")
                .font(.caption)
            Text(
                String(localized: "chat.thought.title", defaultValue: "Thought", bundle: .module)
            )
            .font(.caption)
            .italic()
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(theme.hairline)
                .frame(width: 2)
            Text(thought.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 2)
    }
}
