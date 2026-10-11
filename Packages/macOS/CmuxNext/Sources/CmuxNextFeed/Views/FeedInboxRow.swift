import SwiftUI

/// Snapshot row: an observable feed model never crosses the lazy-list boundary.
struct FeedInboxRow: View {
    let item: FeedItem
    let now: Date
    let selected: Bool
    let pending: Bool
    let threadCount: Int
    let select: () -> Void
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                FeedGlyph(item: item, size: 12).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: item.isUnread ? .semibold : .regular))
                            .foregroundStyle(item.isUnread ? colors.primary : colors.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        UnreadDot(visible: item.isUnread)
                    }
                    PosterLine(item: item, now: now)
                    if threadCount > 1 {
                        Text(FeedStrings.threadCount(threadCount))
                            .font(.system(size: 10.5)).foregroundStyle(colors.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? colors.selection : (hovering ? colors.hover : .clear)))
            .opacity(pending ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
