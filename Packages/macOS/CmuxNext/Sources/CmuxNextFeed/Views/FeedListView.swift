import SwiftUI

/// Variant `list`: one chronological list. Open requests are pinned on top
/// with inline answer controls; notices and closed requests follow, newest
/// first, with unread dots.
struct FeedListView: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        let sections = model.listSections
        VStack(spacing: 0) {
            FeedHeader(model: model)
            if sections.isEmpty {
                FeedEmptyState(text: FeedStrings.empty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections.requests) { item in
                            FeedRequestCard(item: item, model: model)
                            FeedHairline().padding(.horizontal, 14)
                        }
                        ForEach(sections.rest) { item in
                            FeedNoticeRow(item: item, model: model)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

/// Title, badge count, and Mark All Read.
struct FeedHeader: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        let counts = model.counts
        HStack(spacing: 8) {
            Text(FeedStrings.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.primary)
            if counts.badge > 0 {
                Text(verbatim: "\(counts.badge)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(colors.hover))
            }
            Spacer()
            Button { model.markAllRead() } label: {
                Image(systemName: "checkmark.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(colors.secondary)
            .help(FeedStrings.markAllRead)
            .disabled(counts.unreadNotices == 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

/// An open request in the list: what it asks and how to answer, inline.
struct FeedRequestCard: View {
    let item: FeedItem
    let model: FeedModel
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                FeedGlyph(item: item).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.primary)
                        .lineLimit(2)
                    PosterLine(item: item, now: model.now)
                }
                Spacer(minLength: 0)
            }
            FeedPromptSummary(item: item)
                .padding(.leading, 26)
            FeedAnswerControls(item: item, model: model, density: .inline)
                .padding(.leading, 26)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hovering ? colors.hover.opacity(0.5) : .clear)
        .opacity(model.isPending(item.id) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

