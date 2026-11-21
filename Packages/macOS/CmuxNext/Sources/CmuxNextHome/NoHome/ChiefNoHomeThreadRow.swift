#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY: one sidebar row of the no-Home prototype. Every thread kind is the same row (David Beyer: "threads
/// should all be threads"): an avatar, a title, one line of detail, the status and the unread count. The Chief's row
/// alone has a tinted avatar disc and a slightly heavier title, so it reads as the Chief without a panel of its own.
struct ChiefNoHomeThreadRow: View {
    let thread: ChiefNoHomeThread
    var selected = false
    var indent: CGFloat = 0
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(thread.kind == .chief ? .noHomeBodyEmphasis : .noHomeBody)
                    .lineLimit(1)
                if !compact {
                    Text(thread.detail).font(.noHomeCaption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, compact ? 4 : 5)
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatar: some View {
        let side: CGFloat = thread.kind == .subagent || thread.kind == .agent ? 18 : 24
        ZStack {
            if thread.kind == .chief || thread.kind == .otherChief {
                Circle().fill(thread.tint.gradient)
            } else if thread.kind == .group || thread.kind == .direct {
                Circle().fill(thread.tint.opacity(0.2))
            }
            Image(systemName: thread.symbol)
                .font(.noHomeGlyph)
                .foregroundStyle(thread.kind == .chief || thread.kind == .otherChief ? AnyShapeStyle(.white) : AnyShapeStyle(thread.tint))
        }
        .frame(width: side, height: side)
        .frame(width: 24)
    }

    @ViewBuilder private var trailing: some View {
        switch thread.status {
        case .working: ThemedSpinner(size: 10).frame(width: 10, height: 10)
        case .needsYou: Circle().fill(.orange).frame(width: 8, height: 8)
        case .done: Image(systemName: "checkmark").font(.noHomeCaptionEmphasis).foregroundStyle(.green)
        case .idle:
            if thread.unread > 0 {
                Text("\(thread.unread)").font(.noHomeCaptionEmphasis).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
            } else if thread.minutesAgo > 0 {
                Text(thread.minutesAgo < 60 ? "\(thread.minutesAgo)m" : "\(thread.minutesAgo / 60)h")
                    .font(.noHomeCaption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }
}
#endif
