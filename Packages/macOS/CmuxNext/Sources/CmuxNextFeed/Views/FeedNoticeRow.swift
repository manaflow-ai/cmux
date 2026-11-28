import SwiftUI

/// A notice (or a closed request) on one line: dot, glyph, title, poster, time.
struct FeedNoticeRow: View {
    let item: FeedItem
    let model: FeedModel
    var selected = false
    var threadCount = 1
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            UnreadDot(visible: item.isUnread)
            FeedGlyph(item: item, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: item.isUnread ? .medium : .regular))
                    .foregroundStyle(item.isUnread ? colors.primary : colors.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let closed = FeedStrings.closed(item) {
                        Text(closed)
                        Text(verbatim: "·")
                    }
                    PosterLine(item: item, now: model.now)
                    if threadCount > 1 {
                        Text(FeedStrings.threadCount(threadCount))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(colors.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: FeedTunables.rowHeight.value + 10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? colors.selection : (hovering ? colors.hover : .clear))
        )
        .padding(.horizontal, 4)
        .opacity(model.isPending(item.id) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(item.id) }
    }
}
