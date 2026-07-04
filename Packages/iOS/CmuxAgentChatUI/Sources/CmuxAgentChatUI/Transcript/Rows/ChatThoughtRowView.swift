import SwiftUI

/// A collapsed agent reasoning block: a small "Thought" caption.
public struct ChatThoughtRowView: View {
    /// Creates a thought row.
    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            collapsedContent
            Spacer(minLength: 0)
        }
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
}
