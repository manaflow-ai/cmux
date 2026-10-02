import SwiftUI

/// Variant `inbox`: a grouped list on the left (Needs you, Today, Earlier;
/// threads collapsed) and the selected item's detail on the right.
struct FeedInboxView: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        let groups = model.inboxGroups
        // Without a selection the detail previews the first entry; that is
        // view-only and never writes `selection` (user actions only).
        let shown = model.selection.flatMap { model.item($0) } ?? groups.first?.head
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FeedHeader(model: model)
                if groups.all.isEmpty {
                    FeedEmptyState(text: FeedStrings.empty)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            section(FeedStrings.needsYou, groups.needsYou, shown: shown?.id)
                            section(FeedStrings.today, groups.today, shown: shown?.id)
                            section(FeedStrings.earlier, groups.earlier, shown: shown?.id)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(width: 330)
            FeedHairline(vertical: true)
            Group {
                if let shown {
                    FeedInboxDetail(item: shown, thread: groups.all.first { $0.members.contains { $0.id == shown.id } }, model: model)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [FeedInboxEntry], shown: String?) -> some View {
        if !entries.isEmpty {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.secondary)
                Text(verbatim: "\(entries.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(colors.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
            ForEach(entries) { entry in
                FeedNoticeRow(item: entry.head, model: model, selected: entry.members.contains { $0.id == shown },
                              threadCount: entry.members.count)
            }
        }
    }
}

/// The selected item: toolbar, full prompt, diff, answer form, thread.
struct FeedInboxDetail: View {
    let item: FeedItem
    let thread: FeedInboxEntry?
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            FeedDetailToolbar(item: item, model: model)
            FeedHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        FeedGlyph(item: item, size: 15)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(colors.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            PosterLine(item: item, now: model.now)
                        }
                    }
                    FeedPromptSummary(item: item, full: true)
                    if item.isRequest {
                        FeedAnswerControls(item: item, model: model, density: .detail)
                    }
                    if let thread, thread.isThread {
                        FeedHairline()
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(thread.members.filter { $0.id != item.id }) { member in
                                FeedNoticeRow(item: member, model: model)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Done (archive), Snooze, Decline. An open request can only be answered or
/// declined (feed.md 3.6), so Done and Snooze wait until it closes.
struct FeedDetailToolbar: View {
    let item: FeedItem
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            if item.isOpenRequest {
                Button(FeedStrings.decline) { model.decline(item.id) }
                    .buttonStyle(FeedButtonStyle(role: .plain, compact: true))
            } else {
                Menu {
                    Button(FeedStrings.snoozeHour) { model.snooze([item.id], for: 3_600) }
                    Button(FeedStrings.snoozeTomorrow) { model.snooze([item.id], for: 86_400) }
                } label: {
                    Label(FeedStrings.snooze, systemImage: "moon.zzz").font(.system(size: 11.5))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(colors.secondary)
                .fixedSize()
                .padding(.horizontal, 6)
                Button(FeedStrings.done) { model.archive([item.id]) }
                    .buttonStyle(FeedButtonStyle(role: .plain, compact: true))
                    .disabled(item.isArchived)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}
