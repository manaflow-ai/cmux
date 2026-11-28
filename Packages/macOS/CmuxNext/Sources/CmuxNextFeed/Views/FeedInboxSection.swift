import SwiftUI

/// A grouped inbox section containing only value snapshots and user actions.
struct FeedInboxSection: View {
    let title: String
    let entries: [FeedInboxEntry]
    let shown: String?
    let now: Date
    let pendingIDs: Set<String>
    let select: (String) -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        if !entries.isEmpty {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(colors.secondary)
                Text(verbatim: "\(entries.count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(colors.tertiary)
            }
            .padding(.horizontal, 17).padding(.top, 12).padding(.bottom, 4)
            ForEach(entries) { entry in
                FeedInboxRow(item: entry.head, now: now, selected: entry.members.contains { $0.id == shown },
                    pending: entry.members.contains { pendingIDs.contains($0.id) }, threadCount: entry.members.count,
                    select: { select(entry.head.id) })
            }
        }
    }
}
