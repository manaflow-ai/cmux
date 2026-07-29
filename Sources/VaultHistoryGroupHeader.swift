import SwiftUI

/// Pinned section heading for a group of History events.
struct VaultHistoryGroupHeader: View, Equatable {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .cmuxFont(size: 11, weight: .semibold)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(title)
            Text(count, format: .number)
                .cmuxFont(size: 10)
                .foregroundColor(.secondary.opacity(0.6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
