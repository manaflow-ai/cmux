import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// The feed's wide mode. Connection and text filters are client view state;
/// all triage continues through the single feed owner. The Reports tab shows the
/// reports basket (agent reports that wake no model, with a direct reply) in place
/// of the item list and its detail.
struct FeedInboxView: View {
    let model: FeedModel
    var onReportsReply: (@MainActor (ReportReply) async -> Bool)?
    @Environment(\.feedColors) private var colors
    @State private var filter = FeedInboxFilter()
    /// The first appearance picks GitHub when it is connected; switching tabs swaps the shown
    /// child, which appears again, and must not pick it again.
    @State private var pickedConnection = false

    var body: some View {
        VStack(spacing: 0) {
            if filter.connection == .reports {
                VStack(spacing: 0) {
                    header(hasUnread: false, markRead: {})
                    ReportsBasketHost(model: model, onReply: onReportsReply)
                }
            } else {
                inbox
            }
        }
        .onAppear {
            guard !pickedConnection else { return }
            pickedConnection = true
            if model.githubConnectionEnabled { filter.connection = .github }
        }
    }

    private func header(hasUnread: Bool, markRead: @escaping () -> Void) -> FeedInboxHeader {
        FeedInboxHeader(filter: $filter, hasUnread: hasUnread,
            canRefresh: model.onRefresh != nil, canAddConnection: model.onAddConnection != nil,
            markRead: markRead, refresh: { model.refresh() },
            addConnection: { model.onAddConnection?() }, showsReports: onReportsReply != nil)
    }

    @ViewBuilder private var inbox: some View {
        // The model's ordered sections, filtered and grouped once per change (no sort).
        let groups = model.inboxGroups(filter)
        let items = groups.all.flatMap(\.members)
        let shown = filter.selectedItem(model.selection, groups: groups)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header(hasUnread: items.contains(where: \.isUnread), markRead: { model.markRead(items.map(\.id)) })
                if groups.all.isEmpty {
                    FeedEmptyState(text: filter.query.isEmpty && filter.category == .all ? FeedStrings.empty : FeedStrings.noMatches)
                } else {
                    FeedRowsHost(model: model, mode: .inbox, filter: filter)
                }
            }
            .frame(width: 330)
            FeedHairline(vertical: true)
            Group {
                if let shown {
                    FeedInboxDetail(item: shown, thread: groups.all.first { $0.members.contains { $0.id == shown.id } }, model: model)
                } else {
                    VStack(spacing: 12) {
                        // A pack drawing inks about two thirds of its box; 44 matches the 27 pt tray it replaced.
                        Icon(.inboxEmpty, size: 44)
                        Text(FeedStrings.selectInboxItem).font(.system(size: 13))
                    }
                    .foregroundStyle(colors.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
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
                .thinScrollers()
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
                    // Menu labels render through AppKit, which keeps images but not canvases.
                    Label {
                        Text(FeedStrings.snooze)
                    } icon: {
                        Image(nsImage: .icon(.actionSnooze, size: .iconRowSize(forLabelPointSize: 11.5))).renderingMode(.template)
                    }
                    .font(.system(size: 11.5))
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
