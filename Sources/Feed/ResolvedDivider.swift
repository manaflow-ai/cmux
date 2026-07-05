import SwiftUI

/// Dashed separator between pending items and resolved ones.
struct ResolvedDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Text(String(localized: "feed.divider.resolved", defaultValue: "Resolved"))
                .cmuxFont(size: 10, weight: .medium)
                .tracking(0.5)
                .foregroundColor(.secondary.opacity(0.7))
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
