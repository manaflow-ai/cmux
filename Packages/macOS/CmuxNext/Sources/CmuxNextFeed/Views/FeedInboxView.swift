import SwiftUI

/// The feed's wide mode. Connection and text filters are client view state;
/// all triage continues through the single feed owner.
struct FeedInboxView: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors
    @State private var filter = FeedInboxFilter()

    var body: some View {
        let items = filter.items(from: model.visibleItems)
        let groups = FeedInboxGroups(items: items, now: model.now)
        let shown = filter.selectedItem(model.selection, groups: groups)
        let pendingIDs = Set(items.filter { model.isPending($0.id) }.map(\.id))
        let now = model.now
        // Capture actions here, outside LazyVStack. Its child views hold only
        // immutable snapshots and callbacks, never the observable model.
        let select: (String) -> Void = { model.select($0) }
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FeedInboxHeader(filter: $filter, hasUnread: items.contains(where: \.isUnread),
                    canRefresh: model.onRefresh != nil, canAddConnection: model.onAddConnection != nil,
                    markRead: { model.markRead(items.map(\.id)) }, refresh: { model.refresh() },
                    addConnection: { model.onAddConnection?() })
                if groups.all.isEmpty {
                    FeedEmptyState(text: filter.query.isEmpty && filter.category == .all ? FeedStrings.empty : FeedStrings.noMatches)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            FeedInboxSection(title: FeedStrings.needsYou, entries: groups.needsYou,
                                shown: shown?.id, now: now, pendingIDs: pendingIDs, select: select)
                            FeedInboxSection(title: FeedStrings.today, entries: groups.today,
                                shown: shown?.id, now: now, pendingIDs: pendingIDs, select: select)
                            FeedInboxSection(title: FeedStrings.earlier, entries: groups.earlier,
                                shown: shown?.id, now: now, pendingIDs: pendingIDs, select: select)
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(width: 330)
            FeedHairline(vertical: true)
            Group {
                if let shown {
                    FeedInboxDetail(item: shown, thread: groups.all.first { $0.members.contains { $0.id == shown.id } }, model: model)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.system(size: 27, weight: .light))
                        Text(FeedStrings.selectInboxItem).font(.system(size: 13))
                    }
                    .foregroundStyle(colors.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.githubConnectionEnabled { filter.connection = .github }
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
        let now = model.now
        let members = thread?.members.filter { $0.id != item.id } ?? []
        let pendingIDs = Set(members.filter { model.isPending($0.id) }.map(\.id))
        let select: (String) -> Void = { model.select($0) }
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
                    if let detail = model.githubDetail?(item) {
                        FeedGitHubDetailSummary(detail: detail)
                    }
                    FeedPromptSummary(item: item, full: true)
                    if FeedInboxFilter.isGitHub(item), model.onGitHubAction != nil {
                        FeedGitHubActions(item: item, model: model)
                    }
                    if item.isRequest && item.poster.kind != .integration {
                        FeedAnswerControls(item: item, model: model, density: .detail)
                    }
                    if let thread, thread.isThread {
                        FeedHairline()
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(members) { member in
                                FeedInboxRow(item: member, now: now, selected: false,
                                    pending: pendingIDs.contains(member.id), threadCount: 1,
                                    select: { select(member.id) })
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
