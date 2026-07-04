import SwiftUI

/// A collapsed agent reasoning block: a small "Thought" caption.
public struct ChatThoughtRowView: View {
    private let onShowDetail: () -> Void

    /// Creates a thought row.
    public init(onShowDetail: @escaping () -> Void = {}) {
        self.onShowDetail = onShowDetail
    }

    public var body: some View {
        HStack(spacing: 0) {
            collapsedContent
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

    private var collapsedContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "brain")
                .font(.caption)
            Text(
                String(localized: "chat.thought.title", defaultValue: "Thought", bundle: .module)
            )
            .font(.caption)
            .italic()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption2)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
}
